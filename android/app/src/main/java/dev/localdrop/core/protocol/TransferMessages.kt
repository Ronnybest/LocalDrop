package dev.localdrop.core.protocol

/** Builders for the sender side of the transfer messages (protocol/messages.md, «Передача»). */
object TransferMessages {
    class FileInfo(val fileId: Int, val name: String, val mimeType: String, val size: Long, val lastModified: Long?)

    fun request(transferId: ByteArray, files: List<FileInfo>) = Message(
        MessageType.TRANSFER_REQUEST,
        mapOf(
            "transferId" to CborValue.Bytes(transferId),
            "files" to fileArray(files),
            "totalSize" to CborValue.UInt(files.sumOf { it.size }),
        ),
    )

    /** More [files] for a request awaiting its decision; [totalSize] covers all files so far. */
    fun add(transferId: ByteArray, files: List<FileInfo>, totalSize: Long) = Message(
        MessageType.TRANSFER_ADD,
        mapOf(
            "transferId" to CborValue.Bytes(transferId),
            "files" to fileArray(files),
            "totalSize" to CborValue.UInt(totalSize),
        ),
    )

    private fun fileArray(files: List<FileInfo>) = CborValue.Array(
        files.map { file ->
            CborValue.Map(
                buildMap {
                    put("fileId", CborValue.UInt(file.fileId.toLong()))
                    put("name", CborValue.Text(file.name))
                    put("mimeType", CborValue.Text(file.mimeType))
                    put("size", CborValue.UInt(file.size))
                    file.lastModified?.let { put("lastModified", CborValue.int(it)) }
                },
            )
        },
    )

    fun fileBegin(transferId: ByteArray, fileId: Int) = Message(
        MessageType.FILE_BEGIN,
        mapOf(
            "transferId" to CborValue.Bytes(transferId),
            "fileId" to CborValue.UInt(fileId.toLong()),
            // v1 always starts at 0; resume is reserved (protocol/protocol.md §7).
            "offset" to CborValue.UInt(0),
        ),
    )

    /** [data] must be exactly the chunk; it is referenced, not copied, until the message is sent. */
    fun fileChunk(transferId: ByteArray, fileId: Int, offset: Long, data: ByteArray) = Message(
        MessageType.FILE_CHUNK,
        mapOf(
            "transferId" to CborValue.Bytes(transferId),
            "fileId" to CborValue.UInt(fileId.toLong()),
            "offset" to CborValue.UInt(offset),
            "data" to CborValue.Bytes(data),
        ),
    )

    fun fileEnd(transferId: ByteArray, fileId: Int, sha256: ByteArray) = Message(
        MessageType.FILE_END,
        mapOf(
            "transferId" to CborValue.Bytes(transferId),
            "fileId" to CborValue.UInt(fileId.toLong()),
            "sha256" to CborValue.Bytes(sha256),
        ),
    )

    fun transferComplete(transferId: ByteArray) =
        Message(MessageType.TRANSFER_COMPLETE, mapOf("transferId" to CborValue.Bytes(transferId)))

    fun text(transferId: ByteArray, text: String) = Message(
        MessageType.TEXT,
        mapOf("transferId" to CborValue.Bytes(transferId), "text" to CborValue.Text(text)),
    )

    fun cancel(transferId: ByteArray, reason: String) = Message(
        MessageType.CANCEL,
        mapOf("transferId" to CborValue.Bytes(transferId), "reason" to CborValue.Text(reason)),
    )

    // region Receiver side (Mac → phone, protocol.md §2.8)

    fun accept(transferId: ByteArray, fileCount: Int) = Message(
        MessageType.TRANSFER_ACCEPT,
        mapOf("transferId" to CborValue.Bytes(transferId), "fileCount" to CborValue.UInt(fileCount.toLong())),
    )

    fun reject(transferId: ByteArray, reason: String) = Message(
        MessageType.TRANSFER_REJECT,
        mapOf("transferId" to CborValue.Bytes(transferId), "reason" to CborValue.Text(reason)),
    )

    fun fileResult(transferId: ByteArray, fileId: Int, ok: Boolean, code: String? = null) = Message(
        MessageType.FILE_RESULT,
        buildMap {
            put("transferId", CborValue.Bytes(transferId))
            put("fileId", CborValue.UInt(fileId.toLong()))
            put("ok", CborValue.Bool(ok))
            code?.let { put("code", CborValue.Text(it)) }
        },
    )

    fun transferResult(transferId: ByteArray, completed: Boolean, code: String? = null) = Message(
        MessageType.TRANSFER_RESULT,
        buildMap {
            put("transferId", CborValue.Bytes(transferId))
            put("status", CborValue.Text(if (completed) "completed" else "failed"))
            code?.let { put("code", CborValue.Text(it)) }
        },
    )

    // endregion
}
