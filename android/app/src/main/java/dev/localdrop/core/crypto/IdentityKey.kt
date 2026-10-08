package dev.localdrop.core.crypto

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.GeneralSecurityException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/** Long-term device identity (protocol/security.md §2). */
interface IdentityKey {
    val publicKeyX963: ByteArray

    /** ECDSA P-256/SHA-256 signature, DER-encoded. */
    fun sign(data: ByteArray): ByteArray
}

val IdentityKey.fingerprint: ByteArray get() = sha256(publicKeyX963)

class IdentityUnavailableException(message: String, cause: Throwable) : Exception(message, cause)

/**
 * Identity key generated inside Android Keystore. The private key is non-exportable:
 * it never exists in app memory and cannot leave the device.
 */
class KeystoreIdentityKey private constructor(
    private val privateKey: PrivateKey,
    override val publicKeyX963: ByteArray,
) : IdentityKey {

    override fun sign(data: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(privateKey)
        update(data)
        sign()
    }

    companion object {
        private const val TAG = "LD/crypto"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "localdrop.identity.p256.v1"

        /** Performs Keystore I/O; call off the main thread. */
        fun loadOrCreate(): KeystoreIdentityKey = try {
            val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            val existing = keyStore.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry
            val entry = existing ?: run {
                generate()
                keyStore.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry
                    ?: throw GeneralSecurityException("generated key not found in Keystore")
            }
            val publicKey = entry.certificate.publicKey as? ECPublicKey
                ?: throw GeneralSecurityException("identity key is not an EC key")
            KeystoreIdentityKey(entry.privateKey, P256.encodeX963(publicKey)).also {
                Log.i(TAG, "Identity key ${if (existing == null) "generated" else "loaded"}, fingerprint ${it.fingerprint.fingerprintLogPrefix()}…")
            }
        } catch (e: GeneralSecurityException) {
            throw IdentityUnavailableException("Android Keystore identity key unavailable", e)
        } catch (e: java.io.IOException) {
            throw IdentityUnavailableException("Android Keystore could not be loaded", e)
        }

        private fun generate() {
            val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).run {
                initialize(spec)
                generateKeyPair()
            }
        }
    }
}
