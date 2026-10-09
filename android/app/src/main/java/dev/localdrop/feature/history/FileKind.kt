package dev.localdrop.feature.history

import android.webkit.MimeTypeMap
import androidx.annotation.DrawableRes
import dev.localdrop.R
import dev.localdrop.core.history.HistoryEntry

/** What a transferred file is, for its icon and how it opens. */
enum class FileKind(@param:DrawableRes val icon: Int) {
    IMAGE(R.drawable.ic_image),
    VIDEO(R.drawable.ic_video),
    AUDIO(R.drawable.ic_audio),
    APP(R.drawable.ic_android),
    PDF(R.drawable.ic_pdf),
    ARCHIVE(R.drawable.ic_archive),
    DOCUMENT(R.drawable.ic_document),
    SEVERAL(R.drawable.ic_files),
    OTHER(R.drawable.ic_file),
    TEXT(R.drawable.ic_text),
    LINK(R.drawable.ic_link),
    ;

    /** Opened in the gallery rather than in Files. */
    val isVisual: Boolean get() = this == IMAGE || this == VIDEO

    companion object {
        private val archives = setOf("zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz")
        private val documents = setOf(
            "txt", "md", "rtf", "doc", "docx", "odt", "pages", "xls", "xlsx", "ods", "csv", "numbers",
            "ppt", "pptx", "odp", "key", "epub", "json", "xml", "html",
        )

        fun of(entry: HistoryEntry): FileKind = when (entry.kind) {
            HistoryEntry.Kind.TEXT -> TEXT
            HistoryEntry.Kind.LINK -> LINK
            HistoryEntry.Kind.FILES -> if (entry.count > 1) SEVERAL else of(entry.mimeType, entry.title)
        }

        /** From the MIME type when there is a specific one, else from the name's extension. */
        fun of(mimeType: String?, name: String): FileKind {
            val extension = name.substringAfterLast('.', "").lowercase()
            val mime = mimeType?.takeIf { it != "application/octet-stream" }
                ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: ""
            return when {
                mime.startsWith("image/") -> IMAGE
                mime.startsWith("video/") -> VIDEO
                mime.startsWith("audio/") -> AUDIO
                mime == "application/vnd.android.package-archive" || extension == "apk" -> APP
                mime == "application/pdf" -> PDF
                extension in archives || mime == "application/zip" -> ARCHIVE
                extension in documents || mime.startsWith("text/") -> DOCUMENT
                else -> OTHER
            }
        }
    }
}
