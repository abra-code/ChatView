# ChatView

A standalone, transport-pluggable chat component for SwiftUI (macOS / iOS / visionOS).

A transcript above a composer. A `ChatTransport` (the only layer that knows a wire protocol) emits normalized `ChatEvent`s and accepts normalized `ChatCommand`s; the store routes them onto the transcript and the agentic surfaces, and the same view backs AI-agent chat and person-to-person / group chat - the transport and appearance differ, not the view.

## Features

- Streaming Markdown message bodies (one selectable text view per message, via the RichText package) and standalone image items (via AsyncImageCache's CachedImage).
- Agentic surfaces: streamed reasoning folded behind a Thoughts disclosure, tool-call cards that mutate in place through their lifecycle, agent-proposed file diffs rendered as a real line diff (via the DiffView package), a permission gate pinned above the composer, the agent's plan pinned above the transcript, a session status bar (model / mode menus, token / cost usage), and a composer slash-command menu.
- Person-to-person / group chat (dual alignment): timestamps and day separators, sender names and avatars, delivery status with tap-to-retry, emoji reactions, replies, editing and deletion, member / call events, file and voice items, a typing indicator, and paged history.
- Transports behind a registry: `local` (scripted echo / markdown / agentic demo) and `local-p2p` (scripted person-to-person / group demo) are built in; the `ChatViewACP` product adds `acp` (any Agent Client Protocol agent as a subprocess, macOS), the `ChatViewOpenAI` product adds `openai-sse` (any OpenAI-compatible /v1/chat/completions endpoint), and a host registers its own protocol with `ChatTransportRegistry.shared.register(_:factory:)`.
- Session restore in (through the `ChatContentSource` content channel) and incremental persistence out (one `.entry` host event per finalized transcript entry).

## Platforms

macOS 14.6+, iOS 17.6+, visionOS 2.6+. Swift 6.

## Usage

```swift
import ChatView

ChatView(configuration: ChatConfiguration(),
         hostEvents: { event in
             // persist .entry payloads, react to .send / .stop / .error / ...
         })
```

The operational config (which transport, and its settings) is injected at runtime through your `ChatContentSource`'s config channel, never declared in static UI data: `{ "protocol": "local" }` is built in; link `ChatViewACP` / `ChatViewOpenAI` and call `ChatViewACP.register()` / `ChatViewOpenAI.register()` at launch for `"acp"` / `"openai-sse"`. A saved session restores through the same source's content channel; `readOnly` in the configuration makes a pure viewer.

## Demo

A standalone SwiftUI demo app is bundled as an executable target (macOS):

```
swift run ChatViewDemo
```

Three screens behind a segmented picker: People (a 1:1 `local-p2p` session), Group (the four-participant `local-p2p` scenario with member / call events), and ReadOnly (a restored group transcript, no composer). People / Group inject the transport config in code (`{ "protocol": "local-p2p", "transport": { "scenario": ... } }`), so nothing is declared in static UI data. It is the Apple twin of the Kotlin `android/demo` module.

## ActionUI

ActionUI consumers get this component through the ActionUIChat add-on, whose `Chat` element wraps this view for JSON documents, maps element properties to `ChatConfiguration`, and routes host events to ActionUI action IDs.
