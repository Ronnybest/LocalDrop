package dev.localdrop.core.queue

import dev.localdrop.core.transfer.SourceFile
import dev.localdrop.core.transfer.TransferSource
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OutgoingStoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    private var now = 1_000_000L
    private fun store() = OutgoingStore(File(folder.root, "outgoing"), clock = { now })

    private class FakeSource(private val files: List<Pair<String, ByteArray>>, override val clipboardText: String? = null) : TransferSource {
        override val description = "fake"
        override fun files() = files.map { (name, data) ->
            SourceFile(name, "image/jpeg", data.size.toLong(), 42L) { ByteArrayInputStream(data) }
        }
    }

    @Test
    fun spooledFilesSurviveReloadAndReadBack() = runBlocking {
        val photo = ByteArray(300_000) { (it % 251).toByte() }
        val item = store().spool("id-1", "mac-1", FakeSource(listOf("IMG_1.jpg" to photo, "IMG_2.jpg" to byteArrayOf(1, 2, 3))))
        assertEquals(2, item.itemCount)

        val reopened = store().apply { load() }
        val restored = reopened.items.value.single()
        assertEquals("mac-1", restored.deviceId)
        assertNull(restored.text)
        val files = reopened.source(restored).files()
        assertEquals(listOf("IMG_1.jpg", "IMG_2.jpg"), files.map { it.name })
        assertEquals(42L, files.first().lastModified)
        assertArrayEquals(photo, files.first().open().use { it.readBytes() })
    }

    @Test
    fun clipboardTextIsKeptAsText() = runBlocking {
        store().spool("id-2", "mac-1", FakeSource(emptyList(), clipboardText = "https://example.com"))
        val restored = store().apply { load() }.items.value.single()
        assertEquals("https://example.com", restored.text)
        assertTrue(restored.files.isEmpty())
    }

    @Test
    fun interruptedCopyAndExpiredSendsAreDeleted() = runBlocking {
        val root = File(folder.root, "outgoing")
        File(root, "partial").mkdirs()
        File(root, "partial/f0").writeBytes(byteArrayOf(1))
        store().spool("old", "mac-1", FakeSource(listOf("a.jpg" to byteArrayOf(1))))
        now += OutgoingStore.MAX_AGE_MS + 1
        store().spool("new", "mac-1", FakeSource(listOf("b.jpg" to byteArrayOf(2))))

        val reopened = store().apply { load() }
        assertEquals(listOf("new"), reopened.items.value.map { it.id })
        assertFalse(File(root, "partial").exists())
        assertFalse(File(root, "old").exists())
    }

    @Test
    fun failedCopyLeavesNothingBehindAndRemoveDeletes() = runBlocking {
        val broken = object : TransferSource {
            override val description = "broken"
            override fun files() = listOf(SourceFile("x.jpg", "image/jpeg", 10, null) { throw IOException("revoked") })
        }
        val store = store()
        try {
            store.spool("bad", "mac-1", broken)
            fail("expected IOException")
        } catch (e: IOException) {
            // expected
        }
        assertFalse(File(folder.root, "outgoing/bad").exists())

        store.spool("good", "mac-1", FakeSource(listOf("a.jpg" to byteArrayOf(1))))
        store.remove("good")
        assertTrue(store.items.value.isEmpty())
        assertTrue(store().apply { load() }.items.value.isEmpty())
    }
}
