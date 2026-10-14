package dev.nrc.chat

import kotlin.test.*

class ProtocolTest {
    @Test fun unsignedDMAndUtf8MatchTheWireContract() {
        assertContentEquals(hex("0001 800000000000002a 01020304 00 0003 68c3a9"),
            Protocol.send(Long.MIN_VALUE + 42, 0x01020304, "hé"))
        assertContentEquals(hex("0031 0001 800000000000002a 01020304"),
            Protocol.subscribe(listOf(Long.MIN_VALUE + 42), 0x01020304))
        val incoming = hex("0066 800000000000002a 0000000000000011 0003 626f62 0000000000000009 00 0003 68c3a9")
        val message = (Protocol.decode(incoming) as Protocol.Incoming).message
        assertEquals(Long.MIN_VALUE + 42, message.conversationId)
        assertEquals(17, message.sequence)
        assertEquals("bob", message.author)
        assertEquals("hé", message.text)
        incoming.indices.forEach { length -> assertFailsWith<IllegalArgumentException> { Protocol.decode(incoming.copyOf(length)) } }
        assertFailsWith<IllegalArgumentException> { Protocol.decode(incoming + byteArrayOf(0)) }
        val started = Protocol.decode(hex("0079 800000000000002a 0003 626f62 01 00 00 01020304")) as Protocol.DMStarted
        assertEquals(Long.MIN_VALUE + 42, started.conversation.id)
        assertFalse(started.initiator) // peer initiation must not steal the selected conversation
        assertEquals(Long.MIN_VALUE + 42, (Protocol.decode(hex("007c 800000000000002a 01020304")) as Protocol.DMLeft).id)
    }

    @Test fun sendsUseUtf8ByteLimitNotCharacterCount() {
        Protocol.send(2, 1, "é".repeat(25_600))
        assertFailsWith<IllegalArgumentException> { Protocol.send(2, 1, "é".repeat(25_601)) }
        assertFailsWith<IllegalArgumentException> { Protocol.send(2, 1, " \n") }
        assertFailsWith<IllegalArgumentException> { Protocol.send(2, 1, "hello", ByteArray(16)) }
    }

    @Test fun retentionSubscriptionAndAcknowledgementAreDistinct() {
        assertContentEquals(hex("0031 0002 0000000000000002 0000000000000003 01020304"),
            Protocol.subscribe(listOf(2, 3), 0x01020304))
        val ready = Protocol.decode(hex("009e 01020304 0000")) as Protocol.Subscribed
        assertTrue(ready.entries.isEmpty()) // no entries means rooms subscribed but retention disabled
        val ack = Protocol.decode(hex("0067 01020304 0000000000000011 0000000000000009")) as Protocol.Ack
        assertEquals(0x01020304, ack.request)
        assertEquals(17, ack.sequence)
        assertEquals(9, ack.nanos)
    }

    @Test fun acceptsOnlySecureUnambiguousWorkspaceAddresses() {
        assertEquals("wss://nrc.example:443/studio_1", ChatClient.connectionUrl(Profile("https://nrc.example", "studio_1")))
        assertEquals("wss://nrc.example:8443/studio", ChatClient.connectionUrl(Profile("https://nrc.example:8443/", "studio")))
        for (server in listOf("http://nrc.example", "https://nrc.example/path", "https://user:secret@nrc.example", "https://nrc.example?token=x")) {
            assertFailsWith<IllegalArgumentException> { ChatClient.connectionUrl(Profile(server, "studio")) }
        }
        assertFailsWith<IllegalArgumentException> { ChatClient.connectionUrl(Profile("https://nrc.example", "../private")) }
    }

    @Test fun retainedHistoryPreservesTheSendIdentityForLostAckRecovery() {
        val frame = hex("""
            009f 0000000000000002 00 00 00
            0000000000000011 0000000000000000 0000000000000000 01020304 0001
            0000000000000002 0000000000000011 0102030405060708090a0b0c0d0e0f10
            0003 626f62 0000000000000009 00 0003 68c3a9
        """)
        val page = Protocol.decode(frame) as Protocol.Page
        assertEquals(2L, page.id)
        assertEquals("0102030405060708090a0b0c0d0e0f10", page.messages.single().clientMessageId)
        assertEquals("hé", page.messages.single().text)
        assertFalse(page.ascending)
        assertFalse(page.hasMore)
        assertFailsWith<IllegalArgumentException> { Protocol.decode(frame.copyOf(frame.size - 1)) }
    }
}

private fun hex(text: String) = text.filterNot { it.isWhitespace() }.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
