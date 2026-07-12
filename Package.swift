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
    ],
    dependencies: [
        // Sibling standalone components (github.com/abra-code). No released tags yet, so
        // pin the branch; switch to `from: "x.y.z"` once they are tagged.
        .package(url: "https://github.com/abra-code/RichText", branch: "main"),          // renders message Markdown
        .package(url: "https://github.com/abra-code/DiffView", branch: "main"),          // renders tool-card diffs
        .package(url: "https://github.com/abra-code/AsyncImageCache", branch: "main"),   // CachedImage for image items
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
        .testTarget(name: "ChatViewTests", dependencies: ["ChatView"], path: "Tests/ChatViewTests"),
        .testTarget(name: "ChatViewACPTests", dependencies: ["ChatViewACP", "ChatView"], path: "Tests/ACPTests"),
        .testTarget(name: "ChatViewOpenAITests", dependencies: ["ChatViewOpenAI", "ChatView"], path: "Tests/OpenAITests"),
    ]
)
