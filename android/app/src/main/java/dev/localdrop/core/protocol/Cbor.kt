package dev.localdrop.core.protocol

import java.io.ByteArrayOutputStream
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.ByteBuffer

/**
 * Minimal CBOR (RFC 8949) codec for the subset defined in protocol/protocol.md §4:
 * unsigned/negative integers, byte strings, text strings, arrays, maps with text keys,
 * `false`, `true`, `null`. Floats, tags and indefinite lengths are rejected.
 */
sealed interface CborValue {
    data class UInt(val value: Long) : CborValue {
        // Values above Long.MAX_VALUE are rejected by the decoder; the protocol never needs them.
        init {
            require(value >= 0) { "UInt must be non-negative" }
        }
    }

    /** Encodes `-1 - n`. */
    data class NInt(val n: Long) : CborValue

    class Bytes(val value: ByteArray) : CborValue {
        override fun equals(other: Any?): Boolean = other is Bytes && value.contentEquals(other.value)
        override fun hashCode(): Int = value.contentHashCode()
        override fun toString(): String = "Bytes(${value.size})"
    }

    data class Text(val value: String) : CborValue
    data class Array(val items: List<CborValue>) : CborValue
    data class Map(val entries: kotlin.collections.Map<String, CborValue>) : CborValue
    data class Bool(val value: Boolean) : CborValue
    data object Null : CborValue

    companion object {
        fun int(value: Long): CborValue = if (value >= 0) UInt(value) else NInt(-1 - value)
    }
}

class CborException(message: String) : Exception(message)

fun CborValue.Map.text(key: String): String =
    (entries[key] as? CborValue.Text)?.value ?: throw CborException("missing text field '$key'")

fun CborValue.Map.bytes(key: String): ByteArray =
    (entries[key] as? CborValue.Bytes)?.value ?: throw CborException("missing bytes field '$key'")

fun CborValue.Map.uint(key: String): Long =
    (entries[key] as? CborValue.UInt)?.value ?: throw CborException("missing uint field '$key'")

fun CborValue.Map.bool(key: String): Boolean =
    (entries[key] as? CborValue.Bool)?.value ?: throw CborException("missing bool field '$key'")

fun CborValue.Map.array(key: String): List<CborValue> =
    (entries[key] as? CborValue.Array)?.items ?: throw CborException("missing array field '$key'")

object Cbor {
    private const val MAX_DEPTH = 16

    fun encode(value: CborValue): ByteArray = ByteArrayOutputStream().also { write(value, it) }.toByteArray()

    /** Appends the encoding to [out]; lets hot paths reuse one buffer. */
    fun encodeTo(value: CborValue, out: ByteArrayOutputStream) = write(value, out)

    fun decode(data: ByteArray): CborValue {
        val reader = Reader(data)
        val value = reader.readItem(0)
        if (!reader.isAtEnd) throw CborException("trailing bytes after top-level item")
        return value
    }

    private fun write(value: CborValue, out: ByteArrayOutputStream) {
        when (value) {
            is CborValue.UInt -> writeHead(0, value.value, out)
            is CborValue.NInt -> writeHead(1, value.n, out)
            is CborValue.Bytes -> {
                writeHead(2, value.value.size.toLong(), out)
                out.write(value.value)
            }
            is CborValue.Text -> {
                val utf8 = value.value.toByteArray(Charsets.UTF_8)
                writeHead(3, utf8.size.toLong(), out)
                out.write(utf8)
            }
            is CborValue.Array -> {
                writeHead(4, value.items.size.toLong(), out)
                value.items.forEach { write(it, out) }
            }
            is CborValue.Map -> {
                writeHead(5, value.entries.size.toLong(), out)
                // Deterministic order (RFC 8949 §4.2.1): shorter encoded key first, then bytewise.
                val sorted = value.entries.entries.map { it.key.toByteArray(Charsets.UTF_8) to it.value }
                    .sortedWith { a, b ->
                        if (a.first.size != b.first.size) a.first.size - b.first.size
                        else compareUnsigned(a.first, b.first)
                    }
                for ((key, item) in sorted) {
                    writeHead(3, key.size.toLong(), out)
                    out.write(key)
                    write(item, out)
                }
            }
            is CborValue.Bool -> out.write(if (value.value) 0xF5 else 0xF4)
            CborValue.Null -> out.write(0xF6)
        }
    }

    private fun compareUnsigned(a: ByteArray, b: ByteArray): Int {
        for (i in a.indices) {
            val diff = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
            if (diff != 0) return diff
        }
        return 0
    }

    private fun writeHead(major: Int, argument: Long, out: ByteArrayOutputStream) {
        val prefix = major shl 5
        when {
            argument < 0 -> throw IllegalArgumentException("CBOR argument out of range")
            argument < 24 -> out.write(prefix or argument.toInt())
            argument <= 0xFF -> {
                out.write(prefix or 24)
                out.write(argument.toInt())
            }
            argument <= 0xFFFF -> {
                out.write(prefix or 25)
                writeBigEndian(argument, 2, out)
            }
            argument <= 0xFFFF_FFFFL -> {
                out.write(prefix or 26)
                writeBigEndian(argument, 4, out)
            }
            else -> {
                out.write(prefix or 27)
                writeBigEndian(argument, 8, out)
            }
        }
    }

    private fun writeBigEndian(value: Long, byteCount: Int, out: ByteArrayOutputStream) {
        for (shift in (byteCount - 1) downTo 0) out.write((value ushr (shift * 8)).toInt() and 0xFF)
    }

    private class Reader(private val data: ByteArray) {
        private var position = 0

        val isAtEnd: Boolean get() = position == data.size
        private val remaining: Int get() = data.size - position

        private fun readByte(): Int {
            if (position >= data.size) throw CborException("truncated input")
            return data[position++].toInt() and 0xFF
        }

        private fun readUInt(byteCount: Int): Long {
            if (remaining < byteCount) throw CborException("truncated input")
            var value = 0L
            repeat(byteCount) { value = (value shl 8) or (data[position++].toLong() and 0xFF) }
            return value
        }

        private fun readArgument(additional: Int): Long {
            val value = when (additional) {
                in 0..23 -> additional.toLong()
                24 -> readUInt(1)
                25 -> readUInt(2)
                26 -> readUInt(4)
                27 -> readUInt(8)
                31 -> throw CborException("indefinite length is not supported")
                else -> throw CborException("reserved additional info $additional")
            }
            if (value < 0) throw CborException("integer exceeds 63 bits")
            return value
        }

        private fun readLength(additional: Int): Int {
            val length = readArgument(additional)
            // Every item occupies at least one byte, so a count larger than the input is invalid.
            if (length > remaining) throw CborException("declared length exceeds input")
            return length.toInt()
        }

        fun readItem(depth: Int): CborValue {
            if (depth > MAX_DEPTH) throw CborException("nesting too deep")
            val initial = readByte()
            val major = initial shr 5
            val additional = initial and 0x1F
            return when (major) {
                0 -> CborValue.UInt(readArgument(additional))
                1 -> CborValue.NInt(readArgument(additional))
                2 -> {
                    val length = readLength(additional)
                    CborValue.Bytes(data.copyOfRange(position, position + length)).also { position += length }
                }
                3 -> {
                    val length = readLength(additional)
                    val text = decodeUtf8Strict(position, length)
                    position += length
                    CborValue.Text(text)
                }
                4 -> {
                    val count = readLength(additional)
                    CborValue.Array(List(count) { readItem(depth + 1) })
                }
                5 -> {
                    val count = readLength(additional)
                    val entries = LinkedHashMap<String, CborValue>(count)
                    repeat(count) {
                        val key = readItem(depth + 1) as? CborValue.Text
                            ?: throw CborException("map key is not a text string")
                        if (entries.containsKey(key.value)) throw CborException("duplicate map key '${key.value}'")
                        entries[key.value] = readItem(depth + 1)
                    }
                    CborValue.Map(entries)
                }
                6 -> throw CborException("tags are not supported")
                else -> when (additional) {
                    20 -> CborValue.Bool(false)
                    21 -> CborValue.Bool(true)
                    22 -> CborValue.Null
                    25, 26, 27 -> throw CborException("floats are not supported")
                    else -> throw CborException("simple value $additional is not supported")
                }
            }
        }

        private fun decodeUtf8Strict(offset: Int, length: Int): String = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(data, offset, length))
                .toString()
        } catch (e: CharacterCodingException) {
            throw CborException("invalid UTF-8 in text string: ${e.message}")
        }
    }
}
