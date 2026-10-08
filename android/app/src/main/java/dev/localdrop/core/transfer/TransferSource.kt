package dev.localdrop.core.transfer

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** One file to send. [open] is called once, when its data is about to be streamed. */
class SourceFile(
    val name: String,
    val mimeType: String,
    val size: Long,
    val lastModified: Long?,
    val open: () -> InputStream,
)

/** What to send. Resolving the files may do I/O (e.g. ContentResolver queries); call off the main thread. */
interface TransferSource {
    /** A short label for UI before files are resolved. */
    val description: String

    /** Text alone, small enough for the receiver's clipboard; such a source needs no files. */
    val clipboardText: String? get() = null

    /** The individual shares this source sends; more than one for a [BatchSource]. */
    val parts: List<TransferSource> get() = listOf(this)

    @Throws(IOException::class)
    fun files(): List<SourceFile>
}

/** Text sent as a file, for receivers without `clipboardReceive` or text too long for a message. */
fun textSourceFile(text: String): SourceFile {
    val bytes = text.toByteArray(Charsets.UTF_8)
    val stamp = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(Date())
    return SourceFile(
        name = "Text $stamp.txt",
        mimeType = "text/plain",
        size = bytes.size.toLong(),
        lastModified = System.currentTimeMillis(),
        open = { ByteArrayInputStream(bytes) },
    )
}

/**
 * Generated data for testing speed and integrity without touching storage. The content is a
 * deterministic pseudo-random stream, so it doesn't compress and is reproducible.
 */
class TestDataSource(val sizeBytes: Long) : TransferSource {
    override val description: String = "Test data (${label(sizeBytes)})"

    override fun files(): List<SourceFile> = listOf(
        SourceFile(
            name = "LocalDrop-test-${label(sizeBytes).replace(" ", "")}.bin",
            mimeType = "application/octet-stream",
            size = sizeBytes,
            lastModified = System.currentTimeMillis(),
            open = { GeneratedDataInputStream(sizeBytes, SEED) },
        ),
    )

    companion object {
        private const val SEED = 0x4C6F63616C44726FL // "LocalDro"
        const val MB = 1_000_000L
        const val GB = 1_000_000_000L
        val SIZES = listOf(100 * MB, 1 * GB, 5 * GB)

        fun label(bytes: Long): String = if (bytes >= GB) "${bytes / GB} GB" else "${bytes / MB} MB"
    }
}

/** xorshift64* stream of exactly [size] bytes. Fast enough not to limit transfer speed. */
class GeneratedDataInputStream(private val size: Long, seed: Long) : InputStream() {
    private var state = if (seed == 0L) 1L else seed
    private var position = 0L
    private var word = 0L
    private var wordBytesLeft = 0

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) == -1) -1 else one[0].toInt() and 0xFF
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (position >= size) return -1
        val count = minOf(length.toLong(), size - position).toInt()
        for (i in offset until offset + count) {
            if (wordBytesLeft == 0) {
                state = state xor (state ushr 12)
                state = state xor (state shl 25)
                state = state xor (state ushr 27)
                word = state * 0x2545F4914F6CDD1DL
                wordBytesLeft = 8
            }
            buffer[i] = word.toByte()
            word = word ushr 8
            wordBytesLeft--
        }
        position += count
        return count
    }

    override fun available(): Int = minOf(Int.MAX_VALUE.toLong(), size - position).toInt()
}
