package dev.localdrop.core.transport

import android.util.Log
import dev.localdrop.core.crypto.EphemeralKey
import dev.localdrop.core.crypto.HandshakeCrypto
import dev.localdrop.core.crypto.IdentityKey
import dev.localdrop.core.crypto.IdentityUnavailableException
import dev.localdrop.core.crypto.InvalidKeyEncodingException
import dev.localdrop.core.crypto.P256
import dev.localdrop.core.crypto.fingerprintLogPrefix
import dev.localdrop.core.crypto.randomBytes
import dev.localdrop.core.crypto.sha256
import dev.localdrop.core.device.LocalDevice
import dev.localdrop.core.device.TrustState
import dev.localdrop.core.protocol.ClientHello
import dev.localdrop.core.protocol.CborValue
import dev.localdrop.core.protocol.ErrorMessage
import dev.localdrop.core.protocol.Message
import dev.localdrop.core.protocol.MessageType
import dev.localdrop.core.protocol.ProtocolConstants
import dev.localdrop.core.protocol.ServerHello
import dev.localdrop.core.protocol.SessionStatus
import dev.localdrop.core.protocol.presenceKey
import java.io.IOException
import java.net.Socket
import java.security.GeneralSecurityException
import java.security.ProviderException

/** A remote device that proved possession of its identity key during the handshake. */
class PeerIdentity(
    val deviceId: String,
    val name: String,
    val platform: String,
    val identityKey: ByteArray,
    val protocolVersion: Long,
    val capabilities: List<String>,
) {
    val fingerprint: ByteArray = sha256(identityKey)
}

/** Initiator side of the handshake (protocol/security.md §3). Blocking; run on Dispatchers.IO. */
class HandshakeClient(
    private val localDevice: LocalDevice,
    private val identityProvider: () -> IdentityKey,
    private val trustLookup: (deviceId: String, publicKey: ByteArray) -> TrustState,
) {

    class Result(
        val channel: SecureChannel,
        val peer: PeerIdentity,
        val status: SessionStatus,
        /** 6-digit code for pairing; shown only when [status] isn't Trusted. */
        val pairingCode: String,
        /** The peer's presence key, sent with a trusted status. */
        val presenceKey: ByteArray?,
    )

    /**
     * @param expectedDeviceId deviceId learned from BLE; the peer must answer with the same one.
     * @param expectedFingerprint fingerprint learned from BLE. A hint only: a mismatch means we
     *   reached a different device, but a match proves nothing until the signature verifies.
     */
    fun handshake(socket: Socket, expectedDeviceId: String?, expectedFingerprint: ByteArray?): Result {
        val frames = FramedSocket(socket)
        var channel: SecureChannel? = null
        try {
            val identity = try {
                identityProvider()
            } catch (e: IdentityUnavailableException) {
                throw ConnectionException.IdentityUnavailable(e)
            } catch (e: ProviderException) {
                // Keystore hardware/daemon failures surface as ProviderException.
                throw ConnectionException.IdentityUnavailable(e)
            }
            val ephemeral = EphemeralKey.generate()
            val clientNonce = randomBytes(NONCE_SIZE)

            val hello = ClientHello(
                version = ProtocolConstants.VERSION,
                minVersion = ProtocolConstants.MIN_SUPPORTED_VERSION,
                deviceId = localDevice.deviceId,
                name = localDevice.name,
                platform = ProtocolConstants.PLATFORM,
                identityKey = identity.publicKeyX963,
                ephemeralKey = ephemeral.publicKeyX963,
                nonceCommit = sha256(clientNonce),
                capabilities = ProtocolConstants.CAPABILITIES,
            )
            val helloWire = frames.writeFrame(hello.toMessage().encode())
            Log.i(TAG, "client_hello sent to ${frames.remoteDescription}")

            val serverHelloFrame = frames.readFrame(HANDSHAKE_TIMEOUT_MS, "server_hello")
            val serverHello = decoding { ServerHello.from(parseMessage(serverHelloFrame.payload)) }
            if (serverHello.version !in ProtocolConstants.MIN_SUPPORTED_VERSION..ProtocolConstants.VERSION) {
                throw ConnectionException.IncompatibleVersion(listOf(serverHello.version))
            }
            if (expectedDeviceId != null && !serverHello.deviceId.equals(expectedDeviceId, ignoreCase = true)) {
                throw ConnectionException.AuthenticationFailed("a different device answered (${serverHello.deviceId})")
            }
            if (expectedFingerprint != null && !sha256(serverHello.identityKey).contentEquals(expectedFingerprint)) {
                throw ConnectionException.AuthenticationFailed("identity key differs from the one advertised over Bluetooth")
            }
            Log.i(TAG, "server_hello from ${serverHello.deviceId} (${serverHello.platform}, v${serverHello.version})")

            val nonceWire = frames.writeFrame(
                Message(MessageType.CLIENT_NONCE, mapOf("nonce" to CborValue.Bytes(clientNonce))).encode(),
            )

            val transcript = sha256(helloWire, serverHelloFrame.wire, nonceWire)
            val sharedSecret = try {
                ephemeral.agree(serverHello.ephemeralKey)
            } catch (e: InvalidKeyEncodingException) {
                throw ConnectionException.ProtocolViolation("invalid ephemeral key: ${e.message}")
            }
            val keys = HandshakeCrypto.deriveKeys(sharedSecret, transcript)
            val secure = SecureChannel(frames, sendKey = keys.clientToServer, receiveKey = keys.serverToClient)
            channel = secure

            val serverAuth = secure.receive(HANDSHAKE_TIMEOUT_MS, "server_auth")
            val serverSignature = decoding { serverAuth.expect(MessageType.SERVER_AUTH).bytes("sig") }
            val serverVerified = try {
                P256.verify(serverHello.identityKey, HandshakeCrypto.SERVER_AUTH_LABEL + transcript, serverSignature)
            } catch (e: InvalidKeyEncodingException) {
                throw ConnectionException.ProtocolViolation("invalid identity key: ${e.message}")
            }
            if (!serverVerified) throw ConnectionException.AuthenticationFailed("server signature is invalid")

            val clientSignature = try {
                identity.sign(HandshakeCrypto.CLIENT_AUTH_LABEL + transcript)
            } catch (e: GeneralSecurityException) {
                throw ConnectionException.IdentityUnavailable(e)
            } catch (e: ProviderException) {
                throw ConnectionException.IdentityUnavailable(e)
            }
            val localTrust = trustLookup(serverHello.deviceId.lowercase(), serverHello.identityKey)
            if (localTrust == TrustState.KeyChanged) {
                Log.w(TAG, "Known device ${serverHello.deviceId} presented a different identity key")
            }
            secure.send(
                Message(
                    MessageType.CLIENT_AUTH,
                    mapOf(
                        "sig" to CborValue.Bytes(clientSignature),
                        "trusted" to CborValue.Bool(localTrust == TrustState.Trusted),
                        "keyChanged" to CborValue.Bool(localTrust == TrustState.KeyChanged),
                    ),
                ),
            )

            val statusMessage = secure.receive(HANDSHAKE_TIMEOUT_MS, "session_status")
            val status = decoding { SessionStatus.from(statusMessage) }
            val peer = PeerIdentity(
                deviceId = serverHello.deviceId.lowercase(),
                name = serverHello.name,
                platform = serverHello.platform,
                identityKey = serverHello.identityKey,
                protocolVersion = serverHello.version,
                capabilities = serverHello.capabilities,
            )
            Log.i(TAG, "Session with ${peer.deviceId} established, fingerprint ${peer.fingerprint.fingerprintLogPrefix()}…, status ${status.wire}")
            return Result(secure, peer, status, HandshakeCrypto.pairingCode(keys.sasBits), statusMessage.presenceKey())
        } catch (e: ConnectionException) {
            Log.w(TAG, "Handshake with ${frames.remoteDescription} failed: ${e.message}")
            notifyPeer(e, frames, channel)
            frames.close()
            throw e
        }
    }

    private fun notifyPeer(error: ConnectionException, frames: FramedSocket, channel: SecureChannel?) {
        val code = error.wireCode ?: return
        val message = ErrorMessage.create(code, error.message)
        try {
            if (channel != null) channel.send(message) else frames.writeFrame(message.encode())
        } catch (e: ConnectionException) {
            Log.i(TAG, "Could not deliver error $code to peer: ${e.message}")
        } catch (e: IOException) {
            Log.i(TAG, "Could not deliver error $code to peer: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "LD/handshake"
        private const val NONCE_SIZE = 32
        const val HANDSHAKE_TIMEOUT_MS = 15_000L
    }
}
