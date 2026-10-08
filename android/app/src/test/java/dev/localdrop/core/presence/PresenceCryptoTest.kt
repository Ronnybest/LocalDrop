package dev.localdrop.core.presence

import dev.localdrop.core.crypto.DecryptionException
import dev.localdrop.core.discovery.AdvertisedIdentity
import dev.localdrop.core.discovery.AdvertisedStatus
import dev.localdrop.core.discovery.BleScanner
import dev.localdrop.core.protocol.EndpointInfo
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Vectors produced by macos/LocalDrop/Crypto/PresenceKey.swift and Protocol/EndpointInfo.swift. */
class PresenceCryptoTest {
    private val key = ByteArray(32) { it.toByte() }
    private val slot = 1_990_000L

    @Test
    fun tokenAndNameMatchMac() {
        assertEquals("56c5dcf0b1", PresenceCrypto.token(key, slot).hex())
        assertEquals("VsXc8LE", PresenceCrypto.encodeToken(PresenceCrypto.token(key, slot)))
    }

    @Test
    fun scannerRecognizesBothModes() {
        val private = BleScanner.parseIdentity("LVsXc8LE") as AdvertisedIdentity.PrivateToken
        assertArrayEquals(PresenceCrypto.token(key, slot), private.token)
        assertEquals(AdvertisedIdentity.Pairing("588aad"), BleScanner.parseIdentity("P588aad"))
        // A pre-presence name parses as a token but never matches a real presence key.
        val legacy = BleScanner.parseIdentity("LD588aad") as AdvertisedIdentity.PrivateToken
        assertFalse(PresenceCrypto.matches(legacy.token, key, slot * 900_000))
        val noNetwork = BleScanner.parseIdentity("NVsXc8LE") as AdvertisedIdentity.PrivateToken
        assertEquals(AdvertisedStatus.NoNetwork, noNetwork.status)
        assertArrayEquals(PresenceCrypto.token(key, slot), noNetwork.token)
        assertEquals(AdvertisedStatus.Busy, (BleScanner.parseIdentity("BVsXc8LE") as AdvertisedIdentity.PrivateToken).status)
        assertEquals(AdvertisedIdentity.Unknown, BleScanner.parseIdentity("Xabc"))
        assertEquals(AdvertisedIdentity.Unknown, BleScanner.parseIdentity(null))
    }

    @Test
    fun tokenMatchesNeighbouringSlotsOnly() {
        val now = slot * 900_000 + 1_000
        assertTrue(PresenceCrypto.matches(PresenceCrypto.token(key, slot), key, now))
        assertTrue(PresenceCrypto.matches(PresenceCrypto.token(key, slot - 1), key, now))
        assertFalse(PresenceCrypto.matches(PresenceCrypto.token(key, slot - 2), key, now))
        assertFalse(PresenceCrypto.matches(PresenceCrypto.token(key, slot), ByteArray(32), now))
    }

    @Test
    fun opensEndpointSealedByMac() {
        val info = EndpointInfo.decode(SEALED.unhex()) { PresenceCrypto.openEndpoint(key, it) }
        assertEquals("588aad5e-33c5-4dd8-883e-2b45d0d278e3", info.deviceId)
        assertEquals(60398, info.port)
        assertEquals(listOf("10.128.220.110"), info.addresses)
        assertTrue(info.busy)
        assertEquals(listOf("files", "presenceToken"), info.capabilities)
        // A rotated key can't open it.
        assertThrows(DecryptionException::class.java) { PresenceCrypto.openEndpoint(ByteArray(32), sealedPayload()) }
    }

    private fun sealedPayload(): ByteArray {
        // Skip the outer CBOR map header to get at the sealed bytes, via the public decoder.
        var captured = ByteArray(0)
        EndpointInfo.decode(SEALED.unhex()) { captured = it; PresenceCrypto.openEndpoint(key, it) }
        return captured
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun String.unhex() = chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private companion object {
        const val SEALED =
            "a2617601667365616c656458ccd299801c67bacb1d7a150f3ba49601e9f5a52fd8c474f7dcf1cb5752184e666781875fc1c2a82d7179c877feec45bc" +
                "3731d52007c6e33d61a6f019f6ed43e3dbbab8a5b30a1cb35d08eaf1b84d7cba3bfdddb63a4c3e4c8e0653d64f53dee6fb76d31a05c6a42c9a97c4" +
                "96bd811c3e2d3fb7e4729817b451bf067a4f61a2fbd9f48d3f638d32ad5857e7b79ac6b1799b8ade485128c5d2be9ae0832886fda05723997a0152" +
                "7bf9eb2076390ee37266944b3272135f9a80904a978801d3dcef6d973baad0404c707311bb3123"
    }
}
