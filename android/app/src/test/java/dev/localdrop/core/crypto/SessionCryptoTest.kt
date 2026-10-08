package dev.localdrop.core.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

class SessionCryptoTest {

    @Test
    fun hkdfMatchesRfc5869TestCase1() {
        val okm = Hkdf.derive(
            ikm = "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b".hex(),
            salt = "000102030405060708090a0b0c".hex(),
            info = "f0f1f2f3f4f5f6f7f8f9".hex(),
            length = 42,
        )
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", okm.toHex())
    }

    @Test
    fun ecdhAgreesInBothDirections() {
        val a = EphemeralKey.generate()
        val b = EphemeralKey.generate()
        val ab = a.agree(b.publicKeyX963)
        assertEquals(32, ab.size)
        assertArrayEquals(ab, b.agree(a.publicKeyX963))
    }

    @Test
    fun x963RoundTripsAndRejectsPointsOffCurve() {
        val key = EphemeralKey.generate().publicKeyX963
        assertArrayEquals(key, P256.encodeX963(P256.decodeX963(key)))
        val offCurve = key.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertThrows(InvalidKeyEncodingException::class.java) { P256.decodeX963(offCurve) }
        assertThrows(InvalidKeyEncodingException::class.java) { P256.decodeX963(key.copyOf(33)) }
    }

    @Test
    fun verifiesEcdsaSignatures() {
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val publicX963 = P256.encodeX963(pair.public as ECPublicKey)
        val data = "localdrop".toByteArray()
        val sig = Signature.getInstance("SHA256withECDSA").run { initSign(pair.private); update(data); sign() }
        assertTrue(P256.verify(publicX963, data, sig))
        assertFalse(P256.verify(publicX963, "other".toByteArray(), sig))
        assertFalse(P256.verify(publicX963, data, byteArrayOf(0x30, 0x00)))
    }

    @Test
    fun frameCipherRoundTripsInOrderAndRejectsTamperingAndReordering() {
        val key = randomBytes(32)
        val sender = FrameCipher(key)
        val first = sender.seal("one".toByteArray())
        val second = sender.seal("two".toByteArray())

        val receiver = FrameCipher(key)
        assertEquals("one", String(receiver.open(first)))
        assertEquals("two", String(receiver.open(second)))

        // Replaying or reordering shifts the implicit counter, so authentication fails.
        assertThrows(DecryptionException::class.java) { FrameCipher(key).open(second) }
        val tampered = first.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertThrows(DecryptionException::class.java) { FrameCipher(key).open(tampered) }
    }

    @Test
    fun pairingCodeMatchesMacImplementation() {
        // Expected values produced by HandshakeCrypto.pairingCode in macos/LocalDrop/Crypto/SessionCrypto.swift.
        assertEquals("928 559", HandshakeCrypto.pairingCode("deadbeef".hex()))
        assertEquals("000 005", HandshakeCrypto.pairingCode("00000005".hex()))
        assertEquals("967 295", HandshakeCrypto.pairingCode("ffffffff".hex()))
    }

    private fun String.hex(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
