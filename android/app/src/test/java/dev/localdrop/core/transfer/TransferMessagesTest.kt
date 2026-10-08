package dev.localdrop.core.transfer

import dev.localdrop.core.protocol.TransferMessages
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class TransferMessagesTest {

    @Test
    fun generatedDataHasExactSizeAndIsDeterministic() {
        fun digest(size: Long, chunk: Int): ByteArray {
            val md = MessageDigest.getInstance("SHA-256")
            val input = GeneratedDataInputStream(size, 42)
            val buffer = ByteArray(chunk)
            var total = 0L
            while (true) {
                val n = input.read(buffer, 0, buffer.size)
                if (n < 0) break
                md.update(buffer, 0, n)
                total += n
            }
            assertEquals(size, total)
            return md.digest()
        }
        // Same bytes regardless of how the stream is read.
        assertArrayEquals(digest(1_000_003, 4096), digest(1_000_003, 65_537))
        assertNotEquals(digest(1_000_003, 4096).toList(), digest(1_000_004, 4096).toList())
    }

    /** Writes wire samples for the macOS decoder check (see the Swift interop script in the milestone notes). */
    @Test
    fun writesInteropSamples() {
        val transferId = ByteArray(16) { it.toByte() }
        val request = TransferMessages.request(
            transferId,
            listOf(
                TransferMessages.FileInfo(0, "IMG_2841.jpg", "image/jpeg", 2_400_000, 1_700_000_000_000),
                TransferMessages.FileInfo(1, "../../etc/passwd", "text/plain", 0, null),
            ),
        )
        val chunk = TransferMessages.fileChunk(transferId, 0, 262_144, ByteArray(262_144) { (it % 251).toByte() })
        val end = TransferMessages.fileEnd(transferId, 0, ByteArray(32) { 7 })
        val dir = File(System.getProperty("java.io.tmpdir"), "localdrop-interop").apply { mkdirs() }
        File(dir, "request.cbor").writeBytes(request.encode())
        File(dir, "chunk.cbor").writeBytes(chunk.encode())
        File(dir, "end.cbor").writeBytes(end.encode())
        println("Interop samples in $dir")
    }
}
