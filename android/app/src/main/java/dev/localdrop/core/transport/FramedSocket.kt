package dev.localdrop.core.transport

import android.util.Log
import dev.localdrop.core.crypto.DecryptionException
import dev.localdrop.core.crypto.FrameCipher
import dev.localdrop.core.protocol.Cbor
import dev.localdrop.core.protocol.CborException
import dev.localdrop.core.protocol.ErrorCode
import dev.localdrop.core.protocol.ErrorMessage
import dev.localdrop.core.protocol.Message
import dev.localdrop.core.protocol.MessageType
import dev.localdrop.core.protocol.ProtocolConstants
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.net.Socket
import java.net.SocketTimeoutException

/** One frame as received: the payload and the exact wire bytes (for the transcript hash). */
class Frame(val payload: ByteArray, val wire: ByteArray)

/**
 * Length-prefixed frames (`u32 BE length ‖ payload`, protocol/protocol.md §3.1) over a blocking
 * socket. Calls block; run them on Dispatchers.IO. Closing the socket unblocks pending reads.
 */
class FramedSocket(private val socket: Socket) {
    private val input = DataInputStream(BufferedInputStream(socket.getInputStream(), BUFFER_SIZE))
    private val output = BufferedOutputStream(socket.getOutputStream(), BUFFER_SIZE)

    val remoteDescription: String = "${socket.inetAddress?.hostAddress}:${socket.port}"

    /** @param timeoutMs 0 waits indefinitely (used when a watchdog guards the session instead). */
    fun readFrame(timeoutMs: Long, stage: String): Frame {
        socket.soTimeout = timeoutMs.toInt()
        try {
            val length = input.readInt()
            if (length <= 0 || length > ProtocolConstants.MAX_FRAME_SIZE) {
                throw ConnectionException.ProtocolViolation("frame length $length out of range")
            }
            val payload = ByteArray(length)
            input.readFully(payload)
            return Frame(payload, lengthPrefix(length) + payload)
        } catch (e: SocketTimeoutException) {
            throw ConnectionException.Timeout(stage)
        } catch (e: EOFException) {
            throw ConnectionException.ConnectionLost(e)
        } catch (e: IOException) {
            throw ConnectionException.ConnectionLost(e)
        }
    }

    /** Writes one frame and returns its exact wire bytes. */
    fun writeFrame(payload: ByteArray): ByteArray {
        if (payload.size > ProtocolConstants.MAX_FRAME_SIZE) {
            throw ConnectionException.ProtocolViolation("outgoing frame too large")
        }
        val wire = lengthPrefix(payload.size) + payload
        try {
            output.write(wire)
            output.flush()
        } catch (e: IOException) {
            throw ConnectionException.ConnectionLost(e)
        }
        return wire
    }

    /** Writes one frame from a slice of [buffer]; the hot path for file data, no extra copies. */
    fun writeFrame(buffer: ByteArray, offset: Int, length: Int) {
        if (length > ProtocolConstants.MAX_FRAME_SIZE) {
            throw ConnectionException.ProtocolViolation("outgoing frame too large")
        }
        try {
            output.write(lengthPrefix(length))
            output.write(buffer, offset, length)
            output.flush()
        } catch (e: IOException) {
            throw ConnectionException.ConnectionLost(e)
        }
    }

    fun close() {
        try {
            socket.close()
        } catch (e: IOException) {
            Log.w(TAG, "Error closing socket: ${e.message}")
        }
    }

    private fun lengthPrefix(length: Int) = byteArrayOf(
        (length ushr 24).toByte(), (length ushr 16).toByte(), (length ushr 8).toByte(), length.toByte(),
    )

    private companion object {
        const val TAG = "LD/connection"
        const val BUFFER_SIZE = 64 * 1024
    }
}

/** Parses a plaintext or decrypted payload; a peer `error` message becomes an exception. */
internal fun parseMessage(payload: ByteArray): Message {
    val message = try {
        Message.decode(payload)
    } catch (e: CborException) {
        throw ConnectionException.ProtocolViolation(e.message ?: "malformed message")
    }
    if (message.type == MessageType.ERROR) {
        val error = try {
            ErrorMessage.from(message)
        } catch (e: CborException) {
            throw ConnectionException.ProtocolViolation("malformed error message")
        }
        throw if (error.code == ErrorCode.VERSION_UNSUPPORTED) {
            ConnectionException.IncompatibleVersion(error.supported)
        } else {
            ConnectionException.PeerError(error.code, error.detail)
        }
    }
    return message
}

/** Converts schema errors in typed message parsing into protocol violations. */
internal inline fun <T> decoding(block: () -> T): T = try {
    block()
} catch (e: CborException) {
    throw ConnectionException.ProtocolViolation(e.message ?: "malformed message")
}

/**
 * Encrypted message channel established by the handshake. Sending and receiving may happen on
 * different coroutines, but each direction must be used by only one coroutine at a time.
 */
class SecureChannel(
    private val frames: FramedSocket,
    sendKey: ByteArray,
    receiveKey: ByteArray,
) {
    private val sendCipher = FrameCipher(sendKey)
    private val receiveCipher = FrameCipher(receiveKey)
    private val sendLock = Any()

    // Reused across sends: file chunks would otherwise allocate several 256 KiB arrays each.
    private val plaintext = ReusableByteArrayOutputStream(INITIAL_BUFFER_SIZE)
    private var sealed = ByteArray(INITIAL_BUFFER_SIZE)

    val remoteDescription: String get() = frames.remoteDescription

    /** Thread-safe; may be called while another thread is blocked in [receive]. */
    fun send(message: Message) {
        synchronized(sendLock) {
            plaintext.reset()
            Cbor.encodeTo(message.toCbor(), plaintext)
            val needed = plaintext.size() + FrameCipher.TAG_SIZE
            if (sealed.size < needed) sealed = ByteArray(needed)
            val length = sendCipher.seal(plaintext.buffer, 0, plaintext.size(), sealed)
            frames.writeFrame(sealed, 0, length)
        }
    }

    fun receive(timeoutMs: Long, stage: String): Message {
        val frame = frames.readFrame(timeoutMs, stage)
        val plaintext = try {
            receiveCipher.open(frame.payload)
        } catch (e: DecryptionException) {
            throw ConnectionException.DecryptionFailed()
        }
        return parseMessage(plaintext)
    }

    fun close() = frames.close()

    private class ReusableByteArrayOutputStream(size: Int) : ByteArrayOutputStream(size) {
        val buffer: ByteArray get() = buf
    }

    private companion object {
        const val INITIAL_BUFFER_SIZE = ProtocolConstants.CHUNK_SIZE + 1024
    }
}
