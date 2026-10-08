package dev.localdrop.core.transfer

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BatchSourceTest {
    private class OneFile(private val name: String) : TransferSource {
        override val description = name
        override fun files() = listOf(SourceFile(name, "image/jpeg", 1, null) { ByteArrayInputStream(byteArrayOf(1)) })
    }

    @Test
    fun partsJoinUntilTheRequestIsBuilt() {
        val first = OneFile("a.jpg")
        val second = OneFile("b.jpg")
        val batch = BatchSource(first)
        assertTrue(batch.tryAdd(second))

        assertEquals(listOf("a.jpg", "b.jpg"), batch.files().map { it.name })
        assertFalse(batch.tryAdd(OneFile("c.jpg")))
        assertEquals(listOf(first, second), batch.parts)
    }
}
