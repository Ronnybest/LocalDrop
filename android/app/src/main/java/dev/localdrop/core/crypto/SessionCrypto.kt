package dev.localdrop.core.crypto

import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** One-time ECDH P-256 key for a single session. Lives only in memory. */
class EphemeralKey private constructor(private val keyPair: KeyPair) {
    val publicKeyX963: ByteArray = P256.encodeX963(keyPair.public as ECPublicKey)

    /** Returns the 32-byte X coordinate of the shared point, the same value CryptoKit uses. */
    fun agree(peerPublicKeyX963: ByteArray): ByteArray = KeyAgreement.getInstance("ECDH").run {
        init(keyPair.private)
        doPhase(P256.decodeX963(peerPublicKeyX963), true)
        generateSecret()
    }

    companion object {
        fun generate(): EphemeralKey = EphemeralKey(
            KeyPairGenerator.getInstance("EC").run {
                initialize(ECGenParameterSpec("secp256r1"), secureRandom)
                generateKeyPair()
            },
        )
    }
}

val secureRandom = SecureRandom()

fun randomBytes(count: Int): ByteArray = ByteArray(count).also { secureRandom.nextBytes(it) }

/**
 * HKDF-SHA256 (RFC 5869) built from the platform HMAC. Android exposes no HKDF API;
 * this composes standard primitives and implements no cryptography of its own.
 */
object Hkdf {
    private const val HASH_LENGTH = 32

    fun derive(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * HASH_LENGTH) { "invalid HKDF output length" }
        val prk = hmac(if (salt.isEmpty()) ByteArray(HASH_LENGTH) else salt, ikm)
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            previous = hmac(prk, previous + info + byteArrayOf(counter.toByte()))
            val n = minOf(HASH_LENGTH, length - offset)
            previous.copyInto(out, offset, 0, n)
            offset += n
            counter++
        }
        return out
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        doFinal(data)
    }
}

/** Key schedule of protocol/security.md §3. */
object HandshakeCrypto {
    val SERVER_AUTH_LABEL = "localdrop/v1/server-auth".toByteArray(Charsets.UTF_8)
    val CLIENT_AUTH_LABEL = "localdrop/v1/client-auth".toByteArray(Charsets.UTF_8)
    private val C2S_INFO = "localdrop/v1/c2s".toByteArray(Charsets.UTF_8)
    private val S2C_INFO = "localdrop/v1/s2c".toByteArray(Charsets.UTF_8)
    private val SAS_INFO = "localdrop/v1/sas".toByteArray(Charsets.UTF_8)

    class SessionKeys(
        val clientToServer: ByteArray,
        val serverToClient: ByteArray,
        /** Input for the 6-digit pairing code. Never logged. */
        val sasBits: ByteArray,
    )

    /**
     * 6-digit verification code shown on both devices: `uint32_BE(sasBits) mod 1 000 000`,
     * formatted "481 273". Never logged.
     */
    fun pairingCode(sasBits: ByteArray): String {
        require(sasBits.size >= 4) { "sasBits must have 4 bytes" }
        var value = 0L
        for (i in 0 until 4) value = (value shl 8) or (sasBits[i].toLong() and 0xFF)
        val code = (value % 1_000_000).toInt()
        return "%03d %03d".format(code / 1000, code % 1000)
    }

    fun deriveKeys(sharedSecret: ByteArray, transcriptHash: ByteArray) = SessionKeys(
        clientToServer = Hkdf.derive(sharedSecret, transcriptHash, C2S_INFO, 32),
        serverToClient = Hkdf.derive(sharedSecret, transcriptHash, S2C_INFO, 32),
        sasBits = Hkdf.derive(sharedSecret, transcriptHash, SAS_INFO, 4),
    )
}

class DecryptionException : Exception("AES-GCM authentication failed")

/**
 * AES-256-GCM for one direction of a session. Nonce = 4 zero bytes ‖ u64 BE counter,
 * incremented per frame and never transmitted (protocol/security.md §4). Not thread-safe:
 * each direction is used by one coroutine at a time.
 */
class FrameCipher(key: ByteArray) {
    private val keySpec = SecretKeySpec(key, "AES")
    private var counter = 0L
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")

    fun seal(plaintext: ByteArray): ByteArray {
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(TAG_BITS, nextNonce()))
        return cipher.doFinal(plaintext)
    }

    /** Encrypts into [output] (at least `length + TAG_SIZE` bytes) and returns the bytes written. */
    fun seal(input: ByteArray, offset: Int, length: Int, output: ByteArray): Int {
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(TAG_BITS, nextNonce()))
        return cipher.doFinal(input, offset, length, output, 0)
    }

    fun open(ciphertext: ByteArray): ByteArray {
        if (ciphertext.size < TAG_BITS / 8) throw DecryptionException()
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(TAG_BITS, nextNonce()))
        return try {
            cipher.doFinal(ciphertext)
        } catch (e: AEADBadTagException) {
            throw DecryptionException()
        }
    }

    private fun nextNonce(): ByteArray {
        // The counter is a u64 on the wire; a signed Long wrapping negative means 2^63 frames,
        // which is unreachable in practice but still treated as fatal.
        check(counter >= 0) { "frame counter exhausted" }
        val nonce = ByteArray(NONCE_SIZE)
        for (i in 0 until 8) nonce[NONCE_SIZE - 1 - i] = (counter ushr (8 * i)).toByte()
        counter++
        return nonce
    }

    companion object {
        const val TAG_SIZE = 16
        private const val TAG_BITS = 128
        private const val NONCE_SIZE = 12
    }
}
