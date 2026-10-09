package dev.localdrop.core

import dev.localdrop.core.crypto.FrameCipher
import dev.localdrop.core.crypto.HandshakeCrypto
import dev.localdrop.core.crypto.Hkdf
import dev.localdrop.core.crypto.P256
import dev.localdrop.core.crypto.fingerprintDisplay
import dev.localdrop.core.crypto.sha256
import dev.localdrop.core.presence.PresenceCrypto
import dev.localdrop.core.protocol.Cbor
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.protocol.ProtocolConstants
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.spec.ECPrivateKeySpec
import java.util.Properties
import java.util.UUID
import javax.crypto.KeyAgreement

/**
 * protocol/test-vectors.properties, the vectors the Mac's tests check too
 * (macos/LocalDropTests/ProtocolVectorsTests.swift): both sides must agree byte for byte.
 */
class ProtocolVectorsTest {
    private val vectors = Properties().apply {
        // Gradle runs unit tests from the module directory, android/app.
        File("../../protocol/test-vectors.properties").reader(Charsets.UTF_8).use { load(it) }
    }

    private fun text(key: String): String = requireNotNull(vectors.getProperty(key)) { "missing vector $key" }.trim()
    private fun bytes(key: String): ByteArray = text(key).unhex()
    private fun list(key: String): List<String> = text(key).split(',').map { it.trim() }

    @Test
    fun hkdf() {
        assertEquals(text("hkdf.okm"), Hkdf.derive(bytes("hkdf.ikm"), bytes("hkdf.salt"), bytes("hkdf.info"), 42).hex())
    }

    @Test
    fun handshakeKeySchedule() {
        val transcriptHash = sha256(*list("handshake.frames").map { it.unhex() }.toTypedArray())
        assertEquals(text("handshake.transcriptHash"), transcriptHash.hex())

        val shared = ecdh(bytes("handshake.clientEphemeralPrivate"), bytes("handshake.serverEphemeralPublic"))
        assertEquals(text("handshake.sharedSecret"), shared.hex())
        // The other side gets the same secret.
        assertArrayEquals(shared, ecdh(bytes("handshake.serverEphemeralPrivate"), bytes("handshake.clientEphemeralPublic")))

        val keys = HandshakeCrypto.deriveKeys(shared, transcriptHash)
        assertEquals(text("handshake.clientToServerKey"), keys.clientToServer.hex())
        assertEquals(text("handshake.serverToClientKey"), keys.serverToClient.hex())
        assertEquals(text("handshake.sasBits"), keys.sasBits.hex())
        assertEquals(text("handshake.pairingCode"), HandshakeCrypto.pairingCode(keys.sasBits))
    }

    @Test
    fun frameEncryption() {
        val sender = FrameCipher(bytes("frames.key"))
        val receiver = FrameCipher(bytes("frames.key"))
        for ((plaintext, sealed) in list("frames.plaintexts").zip(list("frames.sealed"))) {
            assertEquals(sealed, sender.seal(plaintext.toByteArray()).hex())
            assertEquals(plaintext, String(receiver.open(sealed.unhex())))
        }
    }

    @Test
    fun pairingCodes() {
        for ((sas, code) in list("pairingCode.sasBits").zip(list("pairingCode.codes"))) {
            assertEquals(code, HandshakeCrypto.pairingCode(sas.unhex()))
        }
    }

    @Test
    fun fingerprint() {
        val digest = sha256(bytes("fingerprint.publicKey"))
        assertEquals(text("fingerprint.sha256"), digest.hex())
        assertEquals(text("fingerprint.display"), digest.fingerprintDisplay())
    }

    @Test
    fun presenceTokenAndName() {
        val token = PresenceCrypto.token(bytes("presence.key"), text("presence.slot").toLong())
        assertEquals(text("presence.token"), token.hex())
        assertEquals(text("presence.name"), "L" + PresenceCrypto.encodeToken(token))
    }

    @Test
    fun pendingDeliveryTag() {
        val tag = PresenceCrypto.pendingTag(bytes("presence.key"), text("pending.deviceId"), text("pending.slot").toLong())
        assertEquals(text("pending.tag"), tag.hex())
        assertEquals(text("pending.tag"), ProtocolConstants.pendingDeliveryTag(UUID.fromString(text("pending.uuid")))!!.hex())
    }

    @Test
    fun endpointInfo() {
        val open = bytes("endpoint.cbor")
        // Deterministic encoding: what is decoded encodes to the same bytes.
        assertEquals(open.hex(), Cbor.encode(Cbor.decode(open)).hex())
        val info = EndpointInfo.decode(bytes("endpoint.sealed")) { PresenceCrypto.openEndpoint(bytes("presence.key"), it) }
        assertEquals(text("endpoint.sealed.deviceId"), info.deviceId)
        assertEquals(text("endpoint.sealed.port").toInt(), info.port)
    }

    private fun ecdh(privateScalar: ByteArray, peerPublic: ByteArray): ByteArray {
        val private = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, privateScalar), P256.parameters))
        return KeyAgreement.getInstance("ECDH").run {
            init(private)
            doPhase(P256.decodeX963(peerPublic), true)
            generateSecret()
        }
    }

    private fun String.unhex(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
}
