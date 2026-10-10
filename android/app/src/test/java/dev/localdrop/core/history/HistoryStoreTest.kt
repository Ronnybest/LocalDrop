package dev.localdrop.core.history

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HistoryStoreTest {

    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun forgettingAMacRemovesItsEntriesOnly() {
        val file = folder.newFile("history.cbor").apply { delete() }
        val store = HistoryStore(file)
        store.add(incoming = true, peerId = "mac-a", peerName = "MacBook", kind = HistoryEntry.Kind.TEXT, title = "from a")
        store.add(incoming = false, peerId = "mac-b", peerName = "iMac", kind = HistoryEntry.Kind.TEXT, title = "to b")

        store.removePeer("mac-a", "MacBook")

        assertEquals(listOf("to b"), store.entries.value.map { it.title })
        // And so it stays after a restart.
        assertEquals(listOf("to b"), HistoryStore(file).apply { load() }.entries.value.map { it.title })
    }

    @Test
    fun entriesSavedBeforeIdsGoByName() {
        val legacy = HistoryEntry("1", System.currentTimeMillis(), true, "MacBook", HistoryEntry.Kind.TEXT, "old")
        val other = HistoryEntry("2", System.currentTimeMillis(), true, "iMac", HistoryEntry.Kind.TEXT, "kept")
        val file = folder.newFile("history.cbor").apply { writeBytes(HistoryStore.encode(listOf(legacy, other))) }
        val store = HistoryStore(file)

        store.removePeer("mac-a", "MacBook")

        assertEquals(listOf("kept"), store.entries.value.map { it.title })
    }

    @Test
    fun peerIdSurvivesEncoding() {
        val entry = HistoryEntry("1", 5, false, "MacBook", HistoryEntry.Kind.LINK, "https://example.com", peerId = "mac-a")
        assertEquals("mac-a", HistoryStore.decode(HistoryStore.encode(listOf(entry))).single().peerId)
    }
}
