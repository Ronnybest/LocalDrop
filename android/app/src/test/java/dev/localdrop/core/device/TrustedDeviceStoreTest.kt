package dev.localdrop.core.device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class TrustedDeviceStoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val keyA = ByteArray(65) { 1 }
    private val keyB = ByteArray(65) { 2 }

    private fun store(file: File) = TrustedDeviceStore(file, clock = { 1_000L })

    @Test
    fun persistsAcrossInstancesAndDetectsKeyChange() {
        val file = File(folder.root, "trusted.cbor")
        store(file).trust("mac-1", "MacBook Pro", keyA, ByteArray(32) { 9 })

        val reopened = store(file)
        assertEquals(TrustState.Trusted, reopened.trustState("mac-1", keyA))
        assertEquals(TrustState.KeyChanged, reopened.trustState("mac-1", keyB))
        assertEquals(TrustState.Unknown, reopened.trustState("mac-2", keyA))
        assertEquals("MacBook Pro", reopened.devices.value.single().deviceName)
    }

    @Test
    fun repairingReplacesKeyAndForgetRemoves() {
        val file = File(folder.root, "trusted.cbor")
        val store = store(file)
        store.trust("mac-1", "Mac", keyA, ByteArray(32))
        store.trust("mac-1", "Mac", keyB, ByteArray(32))
        assertEquals(TrustState.Trusted, store.trustState("mac-1", keyB))
        assertEquals(1, store.devices.value.size)

        store.forget("mac-1")
        assertEquals(TrustState.Unknown, store(file).trustState("mac-1", keyB))
    }

    @Test
    fun remembersEndpointAndReadsRecordsWithoutIt() {
        val file = File(folder.root, "trusted.cbor")
        val store = store(file)
        store.trust("mac-1", "Mac", keyA, ByteArray(32))
        // A record written before endpoints were remembered has no address yet.
        assertEquals(emptyList<String>(), store(file).find("mac-1")!!.lastAddresses)

        store.rememberEndpoint("mac-1", listOf("10.0.0.5", "fd00::5"), 60390)
        val reopened = store(file).find("mac-1")!!
        assertEquals(listOf("10.0.0.5", "fd00::5"), reopened.lastAddresses)
        assertEquals(60390, reopened.lastPort)
        // Re-pairing keeps the store consistent and trust intact.
        assertEquals(TrustState.Trusted, store(file).trustState("mac-1", keyA))
    }

    @Test
    fun corruptFileIsMovedAsideAndNothingIsTrusted() {
        val file = File(folder.root, "trusted.cbor")
        file.writeBytes(byteArrayOf(0x1F, 0x00, 0x7F))
        val store = store(file)
        assertEquals(TrustState.Unknown, store.trustState("mac-1", keyA))
        assertTrue(folder.root.listFiles()!!.any { it.name.startsWith("trusted.cbor.corrupt-") })
    }

    @Test
    fun defaultDeviceIsExclusiveAndPersisted() {
        val file = File(folder.root, "trusted.cbor")
        val store = store(file)
        store.trust("mac-1", "Mac 1", keyA, ByteArray(32))
        assertEquals("mac-1", store.devices.value.defaultDevice()?.deviceId)
        store.trust("mac-2", "Mac 2", keyB, ByteArray(32))
        assertEquals(null, store.devices.value.defaultDevice())

        store.setDefault("mac-2")
        store.setDefault("mac-1")
        val reopened = store(file)
        reopened.load()
        assertEquals(listOf("mac-1"), reopened.devices.value.filter { it.isDefault }.map { it.deviceId })
        assertEquals("mac-1", reopened.devices.value.defaultDevice()?.deviceId)
    }
}
