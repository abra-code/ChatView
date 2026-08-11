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
// (OpenAI-compatible /v1/chat/completions streaming), plus `acp-remote` (an ACP agent hosted
// on ANOTHER machine, reached over a WebSocket - the one agentic transport that runs on iOS,
// since it owns no subprocess). Its server half, `chatview-acp-bridge`, is an executable in
// this package. Extracted from the ActionUI ActionUIChat add-on, which now wraps this package
// as its `Chat` element.

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
        // Demo screens shared by BOTH demo apps. The iOS app (Examples/ChatViewDemoiOS, an
        // xcodegen project, since SwiftPM cannot build an iOS app bundle) compiles the same
        // source files directly. One screen, two platforms: a screen that drifted between them
        // would stop being evidence that the transport behaves the same on each.
        .target(name: "ChatViewDemoShared", dependencies: ["ChatView", "ChatViewACP"],
                path: "Examples/Shared"),
        .executableTarget(
            name: "ChatViewDemo",
            // ChatViewACP so the demo can register `acp-remote` and drive a real bridge.
            dependencies: ["ChatView", "ChatViewACP", "ChatViewDemoShared"],
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
        // The demo screen is the REFERENCE host implementation of the checkpoint contract, and
        // the plan calls a non-atomic host the one failure the design cannot close in code. A
        // reference that is only checked by eye is not a reference, so its persistence is tested.
        .testTarget(name: "ChatViewDemoSharedTests", dependencies: ["ChatViewDemoShared", "ChatView"],
                    path: "Tests/DemoSharedTests"),
        .testTarget(name: "ACPBridgeTests", dependencies: ["ACPBridgeCore", "ChatViewACP", "ChatView"], path: "Tests/ACPBridgeTests"),
        .testTarget(name: "ChatViewACPTests", dependencies: ["ChatViewACP", "ChatView"], path: "Tests/ACPTests"),
        .testTarget(name: "ChatViewOpenAITests", dependencies: ["ChatViewOpenAI", "ChatView"], path: "Tests/OpenAITests"),
    ]
)
