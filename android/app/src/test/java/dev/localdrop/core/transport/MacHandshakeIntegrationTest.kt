package dev.localdrop.core.transport

import dev.localdrop.core.crypto.IdentityKey
import dev.localdrop.core.crypto.P256
import dev.localdrop.core.device.LocalDevice
import dev.localdrop.core.device.TrustState
import dev.localdrop.core.protocol.CborValue
import dev.localdrop.core.protocol.ErrorCode
import dev.localdrop.core.protocol.Message
import dev.localdrop.core.protocol.MessageType
import dev.localdrop.core.protocol.SessionStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.UUID

/**
 * Runs the real Kotlin handshake against the running macOS app over loopback.
 * Skipped unless LOCALDROP_MAC_PORT (and LOCALDROP_MAC_ID) are set, e.g.:
 *
 *     LOCALDROP_MAC_PORT=60373 LOCALDROP_MAC_ID=<mac deviceId> ./gradlew testDebugUnitTest
 */
class MacHandshakeIntegrationTest {

    /** Software key standing in for Android Keystore, which doesn't exist on the JVM. */
    private class SoftwareIdentity : IdentityKey {
        private val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        override val publicKeyX963: ByteArray = P256.encodeX963(pair.public as ECPublicKey)
        override fun sign(data: ByteArray): ByteArray =
            Signature.getInstance("SHA256withECDSA").run { initSign(pair.private); update(data); sign() }
    }

    /** With paired devices and pairing mode closed, the Mac refuses to pair a stranger. */
    @Test
    fun strangerIsRefusedOutsidePairingMode() {
        val port = System.getenv("LOCALDROP_MAC_PORT")?.toIntOrNull()
        assumeTrue("LOCALDROP_MAC_PORT not set", port != null)
        assumeTrue("Mac is in pairing mode", System.getenv("LOCALDROP_MAC_PAIRING") != "1")
        val identity = SoftwareIdentity()
        val client = HandshakeClient(
            LocalDevice(UUID.randomUUID().toString(), "JVM stranger"),
            identityProvider = { identity },
            trustLookup = { _, _ -> TrustState.Unknown },
        )
        val socket = Socket().apply { connect(InetSocketAddress("127.0.0.1", port!!), 5_000) }
        val error = assertThrows(ConnectionException.PeerError::class.java) { client.handshake(socket, null, null) }
        assertEquals(ErrorCode.PAIRING_UNAVAILABLE, error.code)
    }

    /** Needs pairing mode open on the Mac (menu › Add a Device…) and LOCALDROP_MAC_PAIRING=1. */
    @Test
    fun completesHandshakeWithMac() {
        val port = System.getenv("LOCALDROP_MAC_PORT")?.toIntOrNull()
        assumeTrue("LOCALDROP_MAC_PORT not set", port != null)
        assumeTrue("Mac not in pairing mode", System.getenv("LOCALDROP_MAC_PAIRING") == "1")
        val macId = System.getenv("LOCALDROP_MAC_ID")?.takeIf { it.isNotBlank() }

        val identity = SoftwareIdentity()
        val client = HandshakeClient(
            LocalDevice(UUID.randomUUID().toString(), "JVM interop test"),
            identityProvider = { identity },
            trustLookup = { _, _ -> TrustState.Unknown },
        )
        val socket = Socket().apply { connect(InetSocketAddress("127.0.0.1", port!!), 5_000) }

        val result = client.handshake(socket, expectedDeviceId = macId, expectedFingerprint = null)
        println("Connected to ${result.peer.name} (${result.peer.platform}), status ${result.status}")
        assertEquals("macos", result.peer.platform)
        assertEquals(SessionStatus.PairingRequired, result.status)
        assertTrue(result.pairingCode.matches(Regex("""\d{3} \d{3}""")))

        // Declining on the phone must end pairing at once, without waiting for the Mac's user.
        result.channel.send(Message(MessageType.PAIRING_CONFIRM, mapOf("accepted" to CborValue.Bool(false))))
        val reply = result.channel.receive(10_000, "pairing_result")
        assertEquals(MessageType.PAIRING_RESULT, reply.type)
        assertFalse(reply.bool("accepted"))
        result.channel.close()
    }

    /**
     * Pairing must react to the phone at any time: a retry from the same device replaces its stale
     * attempt (instead of "busy"), and withdrawing after confirming ends pairing at once.
     */
    @Test
    fun retryReplacesStalePairingAndWithdrawalIsHonoured() {
        val port = System.getenv("LOCALDROP_MAC_PORT")?.toIntOrNull()
        assumeTrue("LOCALDROP_MAC_PORT not set", port != null)
        assumeTrue("Mac not in pairing mode", System.getenv("LOCALDROP_MAC_PAIRING") == "1")
        val identity = SoftwareIdentity()
        val device = LocalDevice(UUID.randomUUID().toString(), "JVM interop retry")
        val client = HandshakeClient(device, identityProvider = { identity }, trustLookup = { _, _ -> TrustState.Unknown })
        fun connect() = client.handshake(Socket().apply { connect(InetSocketAddress("127.0.0.1", port!!), 5_000) }, null, null)
        val confirm = { accepted: Boolean -> Message(MessageType.PAIRING_CONFIRM, mapOf("accepted" to CborValue.Bool(accepted))) }

        val first = connect()
        assertEquals(SessionStatus.PairingRequired, first.status)
        first.channel.send(confirm(true))
        Thread.sleep(300)

        val second = connect()
        assertEquals(SessionStatus.PairingRequired, second.status)
        // The stale session is closed by the Mac.
        assertThrows(ConnectionException::class.java) { first.channel.receive(5_000, "stale session") }

        second.channel.send(confirm(true))
        Thread.sleep(300)
        second.channel.send(confirm(false))
        val reply = second.channel.receive(5_000, "pairing_result")
        assertEquals(MessageType.PAIRING_RESULT, reply.type)
        assertFalse(reply.bool("accepted"))
        second.channel.close()
    }
}
