package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatReplyContentTests.swift.
//
// The `local` transport's canned reply content: the two reply styles (echo, markdown) and the word-preserving
// streaming chunker (chunks must reassemble to the source exactly, so blank lines / indentation / code layout stream
// faithfully). Message Markdown rendering itself is provided by RichText (its own suite), so these cover only the
// transport's own reply logic.

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatReplyContentTest {

    @Test
    fun streamingChunksReassembleExactly() {
        val source = ChatReplyContent.make("markdown", "hi there")
        val chunks = ChatReplyContent.streamingChunks(source)
        assertTrue(chunks.size > 1)
        assertEquals("streaming chunks must reproduce the source exactly", source, chunks.joinToString(""))
    }

    @Test
    fun echoReplyIsPlain() {
        assertEquals("You said: ping", ChatReplyContent.make("echo", "ping"))
    }

    @Test
    fun markdownShowcaseIsMultiBlock() {
        val source = ChatReplyContent.make("markdown", "demo")
        assertTrue("expected an ATX heading", source.contains("## "))
        assertTrue("expected a fenced code block", source.contains("```"))
        assertTrue("expected a GFM table", source.contains("|"))
        assertTrue("expected an unordered list", source.contains("\n- "))
    }

    @Test
    fun sampleImageIsSeededWithDeclaredSize() {
        val image = ChatReplyContent.sampleImage("agent-1")
        assertNotNull(image)
        assertEquals(PixelSize(480.0, 320.0), image!!.pixelSize)
        assertTrue("the demo image is served over https", image.url.startsWith("https://"))
        assertTrue("the seed should key the URL to a stable image", image.url.contains("agent-1"))
    }

    @Test
    fun imageItemExposesItsID() {
        val item: ChatItem = ChatItem.Image(id = "x-image", role = ChatRole.AGENT, image = ChatImage(url = "https://example.test/i.png"))
        assertEquals("x-image", item.id)
    }
}
