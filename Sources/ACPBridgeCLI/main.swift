// Sources/ACPBridgeCLI/main.swift
//
// The bridge executable. Everything of substance lives in ACPBridgeCore; this file is
// argument parsing, the token bootstrap, and a run loop that stops cleanly on a signal.
//
//   chatview-acp-bridge --config bridge.json
//   chatview-acp-bridge --config bridge.json --show-token
//   chatview-acp-bridge --config bridge.json --print-config-snippet

import Foundation
import ChatView
import ACPBridgeCore

#if os(macOS)

private struct StderrLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {
        guard level != .verbose else {
            return
        }
        FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("chatview-acp-bridge: \(message)\n".utf8))
    exit(2)
}

private let usage = """
usage: chatview-acp-bridge --config <path.json> [--show-token] [--print-config-snippet]

  --config <path>           REQUIRED. The bridge config (see the acp-remote plan, section 8.2).
  --show-token              Print the resolved bridge token and exit.
  --print-config-snippet    Print a ready-to-paste ChatView transport config and exit.
"""

var configPath: String?
var showToken = false
var printSnippet = false

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--config":
        guard let next = arguments.first else {
            fail("--config needs a path\n\n\(usage)")
        }
        arguments.removeFirst()
        configPath = next
    case "--show-token":
        showToken = true
    case "--print-config-snippet":
        printSnippet = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown argument '\(argument)'\n\n\(usage)")
    }
}

guard let configPath else {
    fail("--config is required\n\n\(usage)")
}

let configURL = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
let config: BridgeConfig
do {
    config = try BridgeConfig.load(from: configURL)
} catch {
    fail("could not read \(configURL.path): \(error)")
}

let token: String
do {
    token = try BridgeToken.resolve(config: config)
} catch {
    fail("could not resolve the bridge token: \(error)")
}

if showToken {
    print(token)
    exit(0)
}

if printSnippet {
    let snippet: [String: Any] = [
        "protocol": "acp-remote",
        "transport": [
            "url": "ws://\(config.listenHost):\(config.listenPort)/acp",
            "token": token,
            "session": "latest",
        ],
    ]
    // withoutEscapingSlashes because this is meant to be copied and pasted by a human: a URL
    // rendered as ws:\/\/host is valid JSON and looks like a typo.
    let data = try? JSONSerialization.data(withJSONObject: snippet,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    exit(0)
}

private let logger = StderrLogger()
private let bridge = ACPBridge(config: config, token: token, logger: logger)

let port: UInt16
do {
    port = try bridge.start()
} catch {
    fail("could not start: \(error)")
}

FileHandle.standardError.write(Data("""
chatview-acp-bridge \(ACPBridge.bridgeVersion) listening on ws://\(config.listenHost):\(port)/acp
agent: \(config.agent.command.joined(separator: " "))
token: \(token)

This token grants tool execution on this machine through the agent. Treat it as a password,
and do not expose the listener outside a private network without TLS in front of it.

""".utf8))

// SIGINT/SIGTERM are handled through GCD sources so the default terminating disposition never
// fires: the agent subprocess must be torn down through the escalation path, not orphaned.
let signalQueue = DispatchQueue(label: "com.abracode.chatview.acp-bridge.signal")
var sources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        FileHandle.standardError.write(Data("\nchatview-acp-bridge: stopping\n".utf8))
        bridge.stop()
        exit(0)
    }
    source.resume()
    sources.append(source)
}

dispatchMain()

#else

FileHandle.standardError.write(Data("chatview-acp-bridge runs on macOS only (it spawns the agent).\n".utf8))
exit(2)

#endif
