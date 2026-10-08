package dev.localdrop.core.transfer

/**
 * Several shares to the same device sent as one transfer, so the receiver asks once. Parts can
 * be added until the files are resolved for the request; after that, more files reach the
 * receiver only through `transfer_add` (see TransferManager.append).
 */
class BatchSource(first: TransferSource) : TransferSource {
    private val lock = Any()
    private val members = mutableListOf(first)
    private var frozen = false

    override val description: String
        get() = synchronized(lock) { members.singleOrNull()?.description ?: "${members.size} shares" }

    override val parts: List<TransferSource>
        get() = synchronized(lock) { members.toList() }

    /** False once the request has been built from the current parts. */
    fun tryAdd(source: TransferSource): Boolean = synchronized(lock) {
        if (frozen) return false
        members += source
        true
    }

    override fun files(): List<SourceFile> {
        val snapshot = synchronized(lock) {
            frozen = true
            members.toList()
        }
        return snapshot.flatMap { it.files() }
    }
}
