package com.abracode.chatview

// Port of the capability slice of Sources/ChatView/ChatTransport.swift.
//
// Stage A3 seeds only ChatTransportCapabilities here, because the A3 model test (ChatModelV2Test) asserts the
// all-false default - the same reason the Swift ChatModelV2Tests references it from the model suite. A4 adds the
// ChatTransport interface, the config slice, and the factory type to this file (matching the plan's file layout:
// "ChatTransport.kt (protocol + ChatTransportCapabilities)").

/**
 * Which P2P (v2) conversation affordances a transport backs. The store consults this before emitting the
 * corresponding command (typing signals, read marks, paging, ...), and the view combines it with the document's
 * `features` config: an affordance appears only when BOTH the document enables it AND the transport supports it.
 * Every flag defaults to false, so a v1 transport (which does not set `capabilities`) advertises no v2 capability
 * and behaves exactly as before.
 */
data class ChatTransportCapabilities(
    val paging: Boolean = false,               // answers `.loadEarlier` with `.historyPage`
    val typing: Boolean = false,               // relays `.setTyping` / emits `.typingChanged`
    val reactions: Boolean = false,            // relays `.toggleReaction` / emits `.reactionsChanged`
    val editing: Boolean = false,              // relays `.editMessage` / emits `.messageEdited`
    val deletion: Boolean = false,             // relays `.deleteMessage` / emits `.messageDeleted`
    val replies: Boolean = false,              // relays `.sendMessage(replyTo:)`
    val readReceipts: Boolean = false,         // relays `.markRead` / emits status watermarks
    val fileTransfer: Boolean = false,         // emits `.fileAdded` / `.fileProgress`, relays `.cancelFileTransfer`
    val messageIdentity: Boolean = false,      // assigns server-side ids and confirms via `.messageIDConfirmed`
    val reportsConnectionState: Boolean = false, // emits `.connectionStateChanged`; the composer gates on `connected`
)
