# ChatView

A standalone, transport-pluggable chat component for SwiftUI (macOS / iOS / visionOS).

A transcript above a composer. A `ChatTransport` (the only layer that knows a wire protocol) emits normalized `ChatEvent`s and accepts normalized `ChatCommand`s; the store routes them onto the transcript and the agentic surfaces, and the same view backs AI-agent chat and person-to-person / group chat - the transport and appearance differ, not the view.

## Features

- Streaming Markdown message bodies (one selectable text view per message, via the RichText package) and standalone image items (via AsyncImageCache's CachedImage).
- Agentic surfaces: streamed reasoning folded behind a Thoughts disclosure, tool-call cards that mutate in place through their lifecycle, agent-proposed file diffs rendered as a real line diff (via the DiffView package), a permission gate pinned above the composer, the agent's plan pinned above the transcript, a session status bar (model / mode menus, token / cost usage), and a composer slash-command menu.
- Person-to-person / group chat (dual alignment): timestamps and day separators, sender names and avatars, delivery status with tap-to-retry, emoji reactions, replies, editing and deletion, member / call events, file and voice items, a typing indicator, and paged history.
- Transports behind a registry: `local` (scripted echo / markdown / agentic demo) and `local-p2p` (scripted person-to-person / group demo) are built in; the `ChatViewACP` product adds `acp` (any Agent Client Protocol agent as a subprocess, macOS) and `acp-remote` (an ACP agent hosted on another machine, every platform including iOS), the `ChatViewOpenAI` product adds `openai-sse` (any OpenAI-compatible /v1/chat/completions endpoint), and a host registers its own protocol with `ChatTransportRegistry.shared.register(_:factory:)`.
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

Screens behind a segmented picker, including **Remote** - the `acp-remote` transport against a running bridge.

`swift run ChatViewDemo` is the quickest way to poke at a screen, but a SwiftPM executable is not an app bundle: it launches as a background accessory and has no Info.plist, entitlements, or sandbox. For the real thing there are two xcodegen projects, both compiling the SAME sources so they cannot drift from each other or from the package:

```
cd Examples/ChatViewDemoMac  && xcodegen generate && open ChatViewDemoMac.xcodeproj    # macOS, sandboxed
cd Examples/ChatViewDemoiOS  && xcodegen generate && open ChatViewDemoiOS.xcodeproj    # iOS
```

The generated `.xcodeproj` is gitignored; the `project.yml` beside it is the source of truth. Original three screens: People (a 1:1 `local-p2p` session), Group (the four-participant `local-p2p` scenario with member / call events), and ReadOnly (a restored group transcript, no composer). People / Group inject the transport config in code (`{ "protocol": "local-p2p", "transport": { "scenario": ... } }`), so nothing is declared in static UI data. It is the Apple twin of the Kotlin `android/demo` module.

## Remote agent sessions (`acp-remote`)

The `acp` transport spawns an agent as a subprocess, so it is macOS-only. `acp-remote` owns no process, only a WebSocket, and runs everywhere ChatView does - including iOS. The agent lives on another machine and the phone becomes a remote control for it.

That needs a server, which ships in this package: `chatview-acp-bridge` owns one ordinary stdio ACP agent and re-hosts it.

```
swift build -c release --product chatview-acp-bridge
./Scripts/run-bridge-demo.sh          # a scripted agent, for trying it out; --lan for a real device
```

The bridge prints a ready-to-paste transport config. In your own host:

```json
{ "protocol": "acp-remote",
  "transport": { "url": "wss://my-mac.example:8737/acp", "token": "...", "session": "latest" } }
```

| Key | Default | Meaning |
|---|---|---|
| `url` | REQUIRED | `wss://host:port/acp`, or `ws://` to a private host |
| `token` | `""` | bridge token, sent in `initialize` |
| `session` | `"new"` | `"new"`, `"latest"`, or an explicit session id |
| `cwd` | bridge default | working directory for a new session |
| `allowInsecure` | `false` | permit `ws://` to a public host (development only) |
| `handshakeTimeoutSeconds` | `15` | connect + handshake watchdog; `0` disables |
| `resumeAfterSeq` | absent | cold-launch cursor; see below |

**Why this is not just a socket swap.** The connection is not the session. A turn keeps running on the bridge while the phone is backgrounded, killed, or off the network, and the client reattaches and receives exactly what it missed. Transcript item ids are derived from the bridge's sequence numbers, so two devices - and the same device after a relaunch - render identical ids with no reconciliation.

**Cold-launch resume, and the one rule a host must follow.** The transport emits a `.resumeCheckpoint` host event at turn boundaries, carrying `{"sessionId":..., "afterSeq":...}`. Persist it **atomically with the transcript you are already storing from `.entry`**, and on the next launch inject both: the transcript through your content source, and `"session"` + `"resumeAfterSeq"` through the transport config. Both halves or neither. A cursor stored without its transcript silently skips the history before it; a transcript without its cursor replays and duplicates. Storing neither is always safe - the client then replays the whole session, which is what a fresh device does. `Examples/Shared/RemoteAgentScreen.swift` is the reference implementation: it holds entries in memory and writes them together with the cursor in a single file write, so there is never a moment when one exists without the other.

**Android speaks the same protocol.** The Kotlin port ships the transport as its own Gradle module, `:chatview-acp` (`com.abracode:chatview-acp`), for the same reason Swift keeps transports in their own products: it is the only module that pulls OkHttp, so a host that does not drive a remote agent never links it. Add `implementation(project(":chatview-acp"))`, call `ChatViewAcpRemote.register()` at launch, and inject the identical config JSON - same keys, same defaults, same wire protocol against the same bridge. `android/demo`'s **Agent** screen is the Kotlin twin of `RemoteAgentScreen.swift`, checkpoint persistence included. An emulator reaches the bridge on its host at `10.0.2.2`; a real phone needs the Mac's LAN address (`--lan`).

**The token is a credential for code execution.** An ACP agent runs tools on the bridge host, so anyone with the token can run them. The bridge binds `127.0.0.1` by default and writes its token file `0600`; the client refuses cleartext `ws://` to anything that is not loopback, `.local`, RFC 1918, link-local, or CGNAT. Off your own network, put the bridge behind a VPN or a TLS proxy and use `wss://`. ChatView never persists the token: the host injects it at runtime, and should keep it in the Keychain.

## ActionUI

ActionUI consumers get this component through the ActionUIChat add-on, whose `Chat` element wraps this view for JSON documents, maps element properties to `ChatConfiguration`, and routes host events to ActionUI action IDs.
