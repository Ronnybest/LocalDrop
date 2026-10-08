package dev.localdrop.core.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CborTest {

    /** Produced by the macOS implementation (macos/LocalDrop/Protocol/EndpointInfo.swift). */
    private val swiftEndpointInfo =
        "a76176016266705820000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" +
            "626964782435383861616435652d333363352d346464382d383833652d326234356430643237386533" +
            "646e616d6578184d6163426f6f6b2050726f20e2809420d182d0b5d181d18264706f727419ebd5" +
            "656164647273826e31302e3132382e3232302e31313067666430303a3a3168706c6174666f726d656d61636f73"

    @Test
    fun decodesEndpointInfoEncodedBySwift() {
        val info = EndpointInfo.decode(swiftEndpointInfo.hexToBytes())
        assertEquals(1L, info.protocolVersion)
        assertEquals("588aad5e-33c5-4dd8-883e-2b45d0d278e3", info.deviceId)
        assertEquals("MacBook Pro — тест", info.deviceName)
        assertEquals("macos", info.platform)
        assertEquals(60373, info.port)
        assertEquals(listOf("10.128.220.110", "fd00::1"), info.addresses)
        assertArrayEquals(ByteArray(32) { it.toByte() }, info.fingerprint)
    }

    @Test
    fun encodingMatchesSwiftByteForByte() {
        val map = CborValue.Map(
            mapOf(
                "v" to CborValue.UInt(1),
                "id" to CborValue.Text("588aad5e-33c5-4dd8-883e-2b45d0d278e3"),
                "name" to CborValue.Text("MacBook Pro — тест"),
                "platform" to CborValue.Text("macos"),
                "port" to CborValue.UInt(60373),
                "addrs" to CborValue.Array(listOf(CborValue.Text("10.128.220.110"), CborValue.Text("fd00::1"))),
                "fp" to CborValue.Bytes(ByteArray(32) { it.toByte() }),
            ),
        )
        assertEquals(swiftEndpointInfo, Cbor.encode(map).toHex())
    }

    @Test
    fun roundTripsIntegersAtEncodingBoundaries() {
        val values = listOf(0L, 23L, 24L, 255L, 256L, 65_535L, 65_536L, 4_294_967_295L, 4_294_967_296L, Long.MAX_VALUE)
        for (value in values) {
            assertEquals(CborValue.UInt(value), Cbor.decode(Cbor.encode(CborValue.UInt(value))))
            assertEquals(CborValue.int(-value - 1), Cbor.decode(Cbor.encode(CborValue.int(-value - 1))))
        }
    }

    @Test
    fun matchesRfc8949Vectors() {
        assertEquals("1903e8", Cbor.encode(CborValue.UInt(1000)).toHex())
        assertEquals("3863", Cbor.encode(CborValue.int(-100)).toHex())
        assertEquals("6449455446", Cbor.encode(CborValue.Text("IETF")).toHex())
        assertEquals("f5", Cbor.encode(CborValue.Bool(true)).toHex())
        assertEquals("f6", Cbor.encode(CborValue.Null).toHex())
    }

    @Test
    fun rejectsUnsupportedAndMalformedInput() {
        val invalid = listOf(
            "f93c00", // half float
            "c11a514b67b0", // tag
            "5f42010243030405ff", // indefinite-length bytes
            "62c328", // invalid UTF-8
            "a201020304", // non-text map keys
            "a2616101616102", // duplicate key
            "5a7fffffff", // length larger than input
            "0102", // trailing bytes
            "18", // truncated
        )
        for (hex in invalid) {
            assertThrows("expected rejection of $hex", CborException::class.java) { Cbor.decode(hex.hexToBytes()) }
        }
    }

    @Test
    fun rejectsEndpointInfoWithBadFingerprint() {
        val map = CborValue.Map(
            mapOf(
                "v" to CborValue.UInt(1), "id" to CborValue.Text("x"), "name" to CborValue.Text("y"),
                "platform" to CborValue.Text("macos"), "port" to CborValue.UInt(1),
                "addrs" to CborValue.Array(emptyList()), "fp" to CborValue.Bytes(ByteArray(8)),
            ),
        )
        assertThrows(CborException::class.java) { EndpointInfo.decode(Cbor.encode(map)) }
    }

    private fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
