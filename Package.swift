// swift-tools-version: 6.0
//
// ChatView - a standalone, transport-pluggable chat component for SwiftUI (macOS / iOS /
// visionOS). A transcript above a composer; a ChatTransport (the only layer that knows a
// wire protocol) emits normalized ChatEvents and accepts normalized ChatCommands, the
// store routes them onto the transcript and the agentic surfaces (thoughts, tool cards,
// permission gate, plan panel, session status), and the same view backs AI-agent chat and
// person-to-person / group chat. Built-in transports: `local` (scripted echo / markdown /
// agentic demo) and `local-p2p` (scripted person-to-person / group demo). Separate
// products add `acp` (Agent Client Protocol subprocess, macOS) and `openai-sse`
// (OpenAI-compatible /v1/chat/completions streaming). Extracted from the ActionUI
// ActionUIChat add-on, which now wraps this package as its `Chat` element.

import PackageDescription

let package = Package(
    name: "ChatView",
    platforms: [
        .macOS("14.6"),
        .iOS("17.6"),
        .visionOS("2.6"),
    ],
    products: [
        .library(name: "ChatView", targets: ["ChatView"]),
        .library(name: "ChatViewACP", targets: ["ChatViewACP"]),
        .library(name: "ChatViewOpenAI", targets: ["ChatViewOpenAI"]),
        // A standalone SwiftUI demo app (macOS): `swift run ChatViewDemo`. Wires ChatView directly
        // across People / Group / Agent / ReadOnly screens - the Apple twin of the Kotlin android/demo module.
        .executable(name: "ChatViewDemo", targets: ["ChatViewDemo"]),
        // The bridge: re-hosts a local stdio ACP agent over a WebSocket so phones can drive it.
        // macOS only (it spawns the agent); this is the SERVER half of the `acp-remote` transport.
        .executable(name: "chatview-acp-bridge", targets: ["chatview-acp-bridge"]),
    ],
    dependencies: [
        // Sibling standalone components (github.com/abra-code), consumed as versioned releases.
        .package(url: "https://github.com/abra-code/RichText", from: "0.1.0"),          // renders message Markdown
        .package(url: "https://github.com/abra-code/DiffView", from: "0.1.0"),          // renders tool-card diffs
        .package(url: "https://github.com/abra-code/AsyncImageCache", from: "0.1.0"),   // CachedImage for image items
    ],
    targets: [
        .target(
            name: "ChatView",
            dependencies: [
                .product(name: "RichText", package: "RichText"),
                .product(name: "AsyncImageCache", package: "AsyncImageCache"),
                .product(name: "DiffView", package: "DiffView"),
            ],
            path: "Sources/ChatView"
        ),
        // The ACP transport: launches an Agent Client Protocol agent as a subprocess (macOS).
        // Depends on ChatView for the transport contract; registers the `acp` factory.
        .target(name: "ChatViewACP", dependencies: ["ChatView"], path: "Sources/ACP"),
        // The OpenAI SSE transport: streams /v1/chat/completions (llama-server, mlx_lm.server,
        // any OpenAI-compatible endpoint). Cross-platform (URLSession). Registers `openai-sse`.
        .target(name: "ChatViewOpenAI", dependencies: ["ChatView"], path: "Sources/OpenAI"),
        // The standalone demo app (macOS). Bundles transcript-v2-group.json (copied from Fixtures)
        // as the ReadOnly screen's restored transcript.
        .executableTarget(
            name: "ChatViewDemo",
            dependencies: ["ChatView"],
            path: "Examples/ChatViewDemo",
            resources: [.process("transcript-v2-group.json")]
        ),
        // The bridge core: session registry, seq-stamped event log, WebSocket listener, and the
        // routing that re-hosts one stdio ACP agent for many network clients. It reuses
        // ChatViewACP's `package`-visible ACPConnection for the subprocess half rather than
        // re-implementing stdio framing. Every file inside is `#if os(macOS)`.
        .target(name: "ACPBridgeCore", dependencies: ["ChatView", "ChatViewACP"], path: "Sources/ACPBridge"),
        .executableTarget(name: "chatview-acp-bridge", dependencies: ["ACPBridgeCore"], path: "Sources/ACPBridgeCLI"),
        .testTarget(name: "ChatViewTests", dependencies: ["ChatView"], path: "Tests/ChatViewTests"),
        .testTarget(name: "ACPBridgeTests", dependencies: ["ACPBridgeCore", "ChatViewACP", "ChatView"], path: "Tests/ACPBridgeTests"),
        .testTarget(name: "ChatViewACPTests", dependencies: ["ChatViewACP", "ChatView"], path: "Tests/ACPTests"),
        .testTarget(name: "ChatViewOpenAITests", dependencies: ["ChatViewOpenAI", "ChatView"], path: "Tests/OpenAITests"),
    ]
)
