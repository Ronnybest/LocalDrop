package dev.localdrop.core.crypto

import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

class InvalidKeyEncodingException(message: String) : Exception(message)

/** NIST P-256 helpers using the platform JCA provider. Keys travel in X9.63 uncompressed form. */
object P256 {
    const val X963_SIZE = 65
    private const val COORDINATE_SIZE = 32

    /** Curve parameters as the platform provider represents them. */
    val parameters: ECParameterSpec by lazy {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        (generator.generateKeyPair().public as ECPublicKey).params
    }

    fun encodeX963(key: ECPublicKey): ByteArray {
        val out = ByteArray(X963_SIZE)
        out[0] = 0x04
        key.w.affineX.toFixedBytes().copyInto(out, 1)
        key.w.affineY.toFixedBytes().copyInto(out, 1 + COORDINATE_SIZE)
        return out
    }

    /**
     * Parses an uncompressed point and checks it lies on P-256. Not every JCA provider validates
     * this (the desktop JDK doesn't), and an off-curve peer key enables invalid-curve attacks on ECDH.
     */
    fun decodeX963(bytes: ByteArray): ECPublicKey {
        if (bytes.size != X963_SIZE || bytes[0] != 0x04.toByte()) {
            throw InvalidKeyEncodingException("expected 65-byte uncompressed P-256 point")
        }
        val x = BigInteger(1, bytes.copyOfRange(1, 1 + COORDINATE_SIZE))
        val y = BigInteger(1, bytes.copyOfRange(1 + COORDINATE_SIZE, X963_SIZE))
        val p = (parameters.curve.field as ECFieldFp).p
        if (x >= p || y >= p) throw InvalidKeyEncodingException("coordinate out of field range")
        val lhs = y.multiply(y).mod(p)
        val rhs = x.pow(3).add(parameters.curve.a.multiply(x)).add(parameters.curve.b).mod(p)
        if (lhs != rhs) throw InvalidKeyEncodingException("point is not on P-256")
        return try {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), parameters)) as ECPublicKey
        } catch (e: GeneralSecurityException) {
            throw InvalidKeyEncodingException("invalid P-256 point: ${e.message}")
        }
    }

    /** Verifies an ECDSA P-256/SHA-256 signature in DER form. */
    fun verify(publicKeyX963: ByteArray, data: ByteArray, derSignature: ByteArray): Boolean = try {
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(decodeX963(publicKeyX963))
            update(data)
            verify(derSignature)
        }
    } catch (e: java.security.SignatureException) {
        false // malformed DER
    }

    private fun BigInteger.toFixedBytes(): ByteArray {
        val raw = toByteArray() // big-endian two's complement, may carry a leading 0x00
        return when {
            raw.size == COORDINATE_SIZE -> raw
            raw.size > COORDINATE_SIZE -> raw.copyOfRange(raw.size - COORDINATE_SIZE, raw.size)
            else -> ByteArray(COORDINATE_SIZE - raw.size) + raw
        }
    }
}

fun sha256(vararg parts: ByteArray): ByteArray =
    MessageDigest.getInstance("SHA-256").run {
        parts.forEach { update(it) }
        digest()
    }

/** First 16 bytes as uppercase hex in groups of 4, matching the macOS display. */
fun ByteArray.fingerprintDisplay(): String =
    take(16).joinToString("") { "%02X".format(it) }.chunked(4).joinToString(" ")

/** Short prefix safe for logs. */
fun ByteArray.fingerprintLogPrefix(): String = take(4).joinToString("") { "%02x".format(it) }

/**
 * The code both devices of a pair show, for the user to compare at any time after pairing
 * (security.md §2): from both identity keys in a fixed order, 12 digits in groups of 4. Unlike
 * the SAS, it stays the same until either key changes.
 */
fun pairVerificationCode(publicKeyA: ByteArray, publicKeyB: ByteArray): String {
    val (low, high) = if (compareUnsigned(publicKeyA, publicKeyB) <= 0) publicKeyA to publicKeyB else publicKeyB to publicKeyA
    val hash = sha256("localdrop/v1/verify".toByteArray(Charsets.US_ASCII), low, high)
    val value = hash.take(8).fold(0L) { acc, byte -> (acc shl 8) or (byte.toLong() and 0xFF) }
    val code = java.lang.Long.remainderUnsigned(value, 1_000_000_000_000L)
    return "%012d".format(code).chunked(4).joinToString(" ")
}

private fun compareUnsigned(a: ByteArray, b: ByteArray): Int {
    for (i in 0 until minOf(a.size, b.size)) {
        val diff = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
        if (diff != 0) return diff
    }
    return a.size - b.size
}
