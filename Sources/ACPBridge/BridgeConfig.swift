// Sources/ACPBridge/BridgeConfig.swift
//
// The bridge's configuration file, and the token bootstrap that goes with it.
//
// Read section 4.6 of the remote-agent plan before changing anything here. The threat model
// is blunt: this token IS remote code execution on the bridge host, because an ACP agent
// runs tools there. That is why the default bind address is loopback and why the token file
// is 0600.

#if os(macOS)

import Foundation
import ChatViewACP

package struct BridgeAgentConfig: Decodable, Sendable {
    /// argv, resolved the same way the acp transport resolves it (through /usr/bin/env, so a
    /// bare name follows PATH).
    package var command: [String]
    package var cwd: String?
    package var env: [String: String]
    package var mcpServers: [[String: String]]

    private enum CodingKeys: String, CodingKey {
        case command, cwd, env, mcpServers
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode([String].self, forKey: .command)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        mcpServers = try container.decodeIfPresent([[String: String]].self, forKey: .mcpServers) ?? []
    }

    package init(command: [String], cwd: String? = nil,
                 env: [String: String] = [:], mcpServers: [[String: String]] = []) {
        self.command = command
        self.cwd = cwd
        self.env = env
        self.mcpServers = mcpServers
    }
}

package struct BridgeConfig: Decodable, Sendable {

    package var listen: String
    package var agent: BridgeAgentConfig
    package var token: String?
    package var tokenFile: String?
    package var permissionTimeoutSeconds: Double
    package var logDir: String
    package var maxLogEntriesPerSession: Int
    package var retainEndedSessionsDays: Int
    package var handshakeDeadlineSeconds: Double

    package static let defaultSupportDirectory =
        "~/Library/Application Support/chatview-acp-bridge"

    private enum CodingKeys: String, CodingKey {
        case listen, agent, token, tokenFile, permissionTimeoutSeconds
        case logDir, maxLogEntriesPerSession, retainEndedSessionsDays, handshakeDeadlineSeconds
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listen = try container.decodeIfPresent(String.self, forKey: .listen) ?? "127.0.0.1:8737"
        agent = try container.decode(BridgeAgentConfig.self, forKey: .agent)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        tokenFile = try container.decodeIfPresent(String.self, forKey: .tokenFile)
        permissionTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .permissionTimeoutSeconds) ?? 900
        logDir = try container.decodeIfPresent(String.self, forKey: .logDir)
            ?? (Self.defaultSupportDirectory + "/sessions")
        maxLogEntriesPerSession = try container.decodeIfPresent(Int.self, forKey: .maxLogEntriesPerSession) ?? 200_000
        retainEndedSessionsDays = try container.decodeIfPresent(Int.self, forKey: .retainEndedSessionsDays) ?? 14
        handshakeDeadlineSeconds = try container.decodeIfPresent(Double.self, forKey: .handshakeDeadlineSeconds) ?? 10
    }

    /// The in-code initializer the tests use; the decoder above is for the JSON file.
    package init(listen: String = "127.0.0.1:0",
                 agent: BridgeAgentConfig,
                 token: String? = nil,
                 tokenFile: String? = nil,
                 permissionTimeoutSeconds: Double = 900,
                 logDir: String,
                 maxLogEntriesPerSession: Int = 200_000,
                 retainEndedSessionsDays: Int = 14,
                 handshakeDeadlineSeconds: Double = 10) {
        self.listen = listen
        self.agent = agent
        self.token = token
        self.tokenFile = tokenFile
        self.permissionTimeoutSeconds = permissionTimeoutSeconds
        self.logDir = logDir
        self.maxLogEntriesPerSession = maxLogEntriesPerSession
        self.retainEndedSessionsDays = retainEndedSessionsDays
        self.handshakeDeadlineSeconds = handshakeDeadlineSeconds
    }

    package static func load(from url: URL) throws -> BridgeConfig {
        let data = try Data(contentsOf: url)
        var config = try JSONDecoder().decode(BridgeConfig.self, from: data)
        // Relative paths in a config file mean "relative to the config file", not to whatever
        // directory the bridge happened to be started from (launchd starts it at /).
        let base = url.deletingLastPathComponent()
        config.logDir = Self.resolve(config.logDir, against: base)
        config.agent.cwd = config.agent.cwd.map { Self.resolve($0, against: base) }
        config.tokenFile = config.tokenFile.map { Self.resolve($0, against: base) }
        return config
    }

    package static func resolve(_ path: String, against base: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    package var listenHost: String {
        guard let separator = listen.lastIndex(of: ":") else {
            return listen
        }
        return String(listen[listen.startIndex..<separator])
    }

    package var listenPort: UInt16 {
        guard let separator = listen.lastIndex(of: ":"),
              let port = UInt16(listen[listen.index(after: separator)...]) else {
            return 8737
        }
        return port
    }
}

/// Resolves the shared secret: explicit `token`, else `tokenFile`, else a generated one
/// persisted at 0600 under the support directory.
package enum BridgeToken {

    package static func resolve(config: BridgeConfig) throws -> String {
        if let token = config.token, !token.isEmpty {
            return token
        }
        let path = config.tokenFile
            ?? ((BridgeConfig.defaultSupportDirectory as NSString).expandingTildeInPath + "/token")
        let url = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let generated = generate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Create the file 0600 and THEN write it. Writing first and chmod-ing after leaves the
        // token world-readable for the width of that window, and leaves it readable forever if
        // the chmod throws. This secret is tool execution on this host; it never gets to be
        // 0644, not even briefly.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path,
                                             contents: Data(generated.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ACPConnectionError(code: nil, message: "could not create the token file at \(url.path)")
        }
        return generated
    }

    package static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Never silently fall back to a weak token: this secret is remote code execution.
            fatalError("acp-bridge: the system random number generator failed (\(status)); refusing to generate a token")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison. A token check that returns early on the first wrong byte
    /// leaks the secret to anyone who can time the responses.
    package static func matches(_ candidate: String, _ expected: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? Int(a[index]) : 0
            let right = index < b.count ? Int(b[index]) : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}

#endif
