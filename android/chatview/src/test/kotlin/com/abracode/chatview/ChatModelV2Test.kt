package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatModelV2Tests.swift.
//
// Tests for the additive person-to-person / group (v2) model layer: the new ChatMessage fields, the new ChatItem
// cases (memberEvent, callEvent, file / voice), the transcript `participants` roster + version handling, and the
// ChatTransportCapabilities defaults. The cardinal constraint is ADDITIVE: a v1 value must serialize
// byte-identically to before and a v1 document must still decode with every v2 field absent / null.
//
// Emoji are written as \u escapes to keep the source ASCII (matching the Swift emitter's convention); the value
// they round-trip is what matters, not the source spelling (U+1F44D thumbs-up, U+2764 U+FE0F heart).

import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatModelV2Test {

    // Built from code points so the source stays ASCII: U+1F44D thumbs-up, U+2764 + U+FE0F red heart.
    private val thumbsUp = String(Character.toChars(0x1F44D))
    private val heart = String(Character.toChars(0x2764)) + String(Character.toChars(0xFE0F))

    private fun encode(message: ChatMessage) = chatJson.encodeToJsonElement(ChatMessage.serializer(), message)
    private fun encode(item: ChatItem) = chatJson.encodeToJsonElement(ChatItem.serializer(), item)
    private fun encode(transcript: ChatTranscript) = chatJson.encodeToJsonElement(ChatTranscript.serializer(), transcript)

    private fun decodeMessage(json: String) = chatJson.decodeFromString(ChatMessage.serializer(), json)
    private fun decodeItem(json: String) = chatJson.decodeFromString(ChatItem.serializer(), json)
    private fun decodeTranscript(json: String) = chatJson.decodeFromString(ChatTranscript.serializer(), json)

    private fun <T> roundTrip(serializer: kotlinx.serialization.KSerializer<T>, value: T): T =
        chatJson.decodeFromJsonElement(serializer, chatJson.encodeToJsonElement(serializer, value))

    // MARK: - v1 byte-identity (the additive guardrail)

    @Test
    fun v1MessageEncodesWithoutAnyV2Keys() {
        val message = ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "Hi", isStreaming = false)
        assertEquals(
            "a v1 message must not emit senderID/timestamp/status/... when they are null",
            """{"id":"u1","role":"local","text":"Hi"}""",
            canonicalJson(encode(message)),
        )
    }

    @Test
    fun v1TranscriptShapeIsUnchanged() {
        val transcript = ChatTranscript(
            items = listOf(ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "Hi", isStreaming = false))),
        )
        assertEquals(
            """{"items":[{"message":{"id":"u1","role":"local","text":"Hi"},"type":"message"}],"version":1}""",
            canonicalJson(encode(transcript)),
        )
    }

    @Test
    fun v1MessageJSONDecodesWithNullV2Fields() {
        val message = decodeMessage("""{"id":"u1","role":"remote","text":"hello"}""")
        assertEquals("u1", message.id)
        assertEquals(ChatRole.REMOTE, message.role)
        assertNull(message.senderID)
        assertNull(message.timestamp)
        assertNull(message.status)
        assertNull(message.reactions)
        assertNull(message.editedAt)
        assertNull(message.replyTo)
        assertNull(message.deleted)
    }

    // MARK: - v2 round-trips

    @Test
    fun messageWithAllV2FieldsRoundTrips() {
        val message = ChatMessage(
            id = "m1", role = ChatRole.REMOTE, text = "See attached", isStreaming = false,
            senderID = "p2", senderName = "Alex", avatarURL = "https://ex.test/a.png",
            timestamp = "2026-07-10T12:00:00Z", status = MessageStatus.READ,
            reactions = listOf(
                Reaction(emoji = thumbsUp, count = 2, mine = true),
                Reaction(emoji = heart, count = 1, mine = false),
            ),
            editedAt = "2026-07-10T12:01:00Z",
            replyTo = ReplyRef(itemID = "m0", excerpt = "prior", senderName = "Me"),
            deleted = false,
        )
        val decoded = roundTrip(ChatMessage.serializer(), message)
        assertEquals(message, decoded)
        assertEquals(MessageStatus.READ, decoded.status)
        assertEquals(2, decoded.reactions?.size)
        assertEquals("m0", decoded.replyTo?.itemID)
    }

    @Test
    fun memberEventRoundTrips() {
        val item: ChatItem = ChatItem.MemberEventItem(
            MemberEvent(
                id = "ev1", timestamp = "2026-07-10T12:00:00Z", kind = MemberEvent.Kind.RENAMED,
                actorName = "Alex", subjectName = "Group", detail = "Weekend Trip",
            ),
        )
        val decoded = roundTrip(ChatItem.serializer(), item)
        assertEquals(item, decoded)
        val event = (decoded as ChatItem.MemberEventItem).event
        assertEquals(MemberEvent.Kind.RENAMED, event.kind)
        assertEquals("Weekend Trip", event.detail)
    }

    @Test
    fun callEventRoundTrips() {
        val item: ChatItem = ChatItem.CallEventItem(
            CallEvent(
                id = "call1", timestamp = "2026-07-10T12:00:00Z", kind = CallEvent.Kind.COMPLETED,
                durationSeconds = 143, isVideo = true,
            ),
        )
        val decoded = roundTrip(ChatItem.serializer(), item)
        assertEquals(item, decoded)
        val event = (decoded as ChatItem.CallEventItem).event
        assertEquals(143, event.durationSeconds)
        assertEquals(true, event.isVideo)
    }

    @Test
    fun fileItemRoundTrips() {
        val item: ChatItem = ChatItem.File(
            ChatFile(
                id = "f1", role = ChatRole.LOCAL, senderID = "me", senderName = "Me",
                timestamp = "2026-07-10T12:00:00Z", status = MessageStatus.SENT, name = "report.pdf",
                sizeBytes = 20480, url = "file:///tmp/report.pdf", kind = ChatFile.Kind.FILE,
                durationSeconds = null, transferStatus = FileTransferStatus.TRANSFERRING, progress = 0.42,
            ),
        )
        val decoded = roundTrip(ChatItem.serializer(), item)
        assertEquals(item, decoded)
        val file = (decoded as ChatItem.File).file
        assertEquals(ChatFile.Kind.FILE, file.kind)
        assertEquals(FileTransferStatus.TRANSFERRING, file.transferStatus)
        assertEquals(0.42, file.progress!!, 0.0)
    }

    @Test
    fun voiceFileItemRoundTrips() {
        val item: ChatItem = ChatItem.File(
            ChatFile(
                id = "v1", role = ChatRole.REMOTE, name = "voice.m4a", sizeBytes = 8192,
                url = "https://ex.test/v.m4a", kind = ChatFile.Kind.VOICE,
                durationSeconds = 12, transferStatus = FileTransferStatus.COMPLETED,
            ),
        )
        val decoded = roundTrip(ChatItem.serializer(), item)
        assertEquals(item, decoded)
        val file = (decoded as ChatItem.File).file
        assertEquals(ChatFile.Kind.VOICE, file.kind)
        assertEquals(12, file.durationSeconds)
    }

    @Test
    fun fileKindAndTransferStatusDefaultWhenAbsent() {
        val decoded = decodeItem("""{"type":"file","file":{"id":"f2","role":"remote","name":"x.txt"}}""")
        val file = (decoded as ChatItem.File).file
        assertEquals(ChatFile.Kind.FILE, file.kind)
        assertEquals(FileTransferStatus.COMPLETED, file.transferStatus)
        assertNull(file.progress)
    }

    // MARK: - Transcript roster + version

    @Test
    fun v2TranscriptRoundTrips() {
        val transcript = ChatTranscript(
            version = 2,
            items = listOf(
                ChatItem.Message(
                    ChatMessage(
                        id = "m1", role = ChatRole.REMOTE, text = "Hi", isStreaming = false,
                        senderID = "p2", timestamp = "2026-07-10T12:00:00Z", status = MessageStatus.DELIVERED,
                    ),
                ),
                ChatItem.MemberEventItem(MemberEvent(id = "ev1", kind = MemberEvent.Kind.JOINED, subjectName = "Sam")),
                ChatItem.CallEventItem(CallEvent(id = "c1", kind = CallEvent.Kind.MISSED_INCOMING)),
                ChatItem.File(ChatFile(id = "f1", role = ChatRole.LOCAL, name = "a.pdf", transferStatus = FileTransferStatus.COMPLETED)),
            ),
            participants = listOf(
                Participant(id = "me", name = "Me", isSelf = true),
                Participant(id = "p2", name = "Alex", avatarURL = "https://ex.test/a.png"),
            ),
        )
        val decoded = roundTrip(ChatTranscript.serializer(), transcript)
        assertEquals(transcript, decoded)
        assertEquals(2, decoded.version)
        assertEquals(2, decoded.participants?.size)
        assertEquals(true, decoded.participants?.first()?.isSelf)
    }

    @Test
    fun decoderAcceptsVersion1And2() {
        val v1 = decodeTranscript("""{"version":1,"items":[{"type":"system","id":"s","text":"hi"}]}""")
        assertEquals(1, v1.version)
        assertNull(v1.participants)

        val v2 = decodeTranscript("""{"version":2,"items":[],"participants":[{"id":"p1","name":"Alex"}]}""")
        assertEquals(2, v2.version)
        assertEquals("Alex", v2.participants?.first()?.name)
    }

    @Test
    fun v2RestoreThroughDecodeFrom() {
        val string = """{"version":2,"items":[{"type":"memberEvent","memberEvent":{"id":"ev1","kind":"joined","subjectName":"Sam"}}],"participants":[{"id":"me","name":"Me","isSelf":true}]}"""
        val decoded = ChatTranscript.decode(string)
        assertEquals(2, decoded?.version)
        assertEquals(1, decoded?.participants?.size)
        val event = (decoded?.items?.first() as ChatItem.MemberEventItem).event
        assertEquals("Sam", event.subjectName)
    }

    // Not a Swift port: an explicit JSON null on an optional transcript key is treated as absent (mirrors Swift's
    // decodeIfPresent, which returns nil / the default for both a missing key and a null value). Neither platform
    // emits these forms, but a hand-authored / corrupt restore payload must degrade the same way.
    @Test
    fun explicitNullsInTranscriptDecodeAsAbsent() {
        val decoded = decodeTranscript("""{"version":null,"items":null,"usage":null,"plan":null,"title":null,"participants":null}""")
        assertEquals(1, decoded.version)
        assertTrue(decoded.items.isEmpty())
        assertNull(decoded.usage)
        assertTrue(decoded.plan.isEmpty())
        assertNull(decoded.title)
        assertNull(decoded.participants)
    }

    // MARK: - Value-type helpers + capabilities

    @Test
    fun messageStatusWatermarkLadder() {
        assertTrue(MessageStatus.SENDING.watermarkRank!! < MessageStatus.SENT.watermarkRank!!)
        assertTrue(MessageStatus.SENT.watermarkRank!! < MessageStatus.DELIVERED.watermarkRank!!)
        assertTrue(MessageStatus.DELIVERED.watermarkRank!! < MessageStatus.READ.watermarkRank!!)
        assertNull("failed is outside the ladder", MessageStatus.FAILED.watermarkRank)
    }

    @Test
    fun messageStatusWireValues() {
        // The wire strings the ports and transports share.
        assertEquals("sending", wire(MessageStatus.SENDING))
        assertEquals("sent", wire(MessageStatus.SENT))
        assertEquals("delivered", wire(MessageStatus.DELIVERED))
        assertEquals("read", wire(MessageStatus.READ))
        assertEquals("failed", wire(MessageStatus.FAILED))
    }

    @Test
    fun defaultTransportCapabilitiesAreAllFalse() {
        val caps = ChatTransportCapabilities()
        assertFalse(caps.paging)
        assertFalse(caps.typing)
        assertFalse(caps.reactions)
        assertFalse(caps.editing)
        assertFalse(caps.deletion)
        assertFalse(caps.replies)
        assertFalse(caps.readReceipts)
        assertFalse(caps.fileTransfer)
        assertFalse(caps.messageIdentity)
        assertFalse(caps.reportsConnectionState)
    }

    @Test
    fun connectionStateWireValuesRoundTrip() {
        for (state in listOf(
            ChatConnectionState.CONNECTING, ChatConnectionState.CONNECTED,
            ChatConnectionState.RECONNECTING, ChatConnectionState.OFFLINE,
        )) {
            val encoded = chatJson.encodeToJsonElement(ChatConnectionState.serializer(), state)
            assertEquals(state, chatJson.decodeFromJsonElement(ChatConnectionState.serializer(), encoded))
        }
        assertEquals("connecting", wire(ChatConnectionState.CONNECTING))
        assertEquals("connected", wire(ChatConnectionState.CONNECTED))
        assertEquals("reconnecting", wire(ChatConnectionState.RECONNECTING))
        assertEquals("offline", wire(ChatConnectionState.OFFLINE))
    }

    private fun wire(status: MessageStatus): String =
        chatJson.encodeToJsonElement(MessageStatus.serializer(), status).jsonPrimitive.content

    private fun wire(state: ChatConnectionState): String =
        chatJson.encodeToJsonElement(ChatConnectionState.serializer(), state).jsonPrimitive.content
}
