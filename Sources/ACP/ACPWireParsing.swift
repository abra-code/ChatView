// Sources/ACP/ACPWireParsing.swift
//
// The pure ACP payload parsers: JSON-RPC params in, ChatView model types out.
//
// Deliberately NOT wrapped in `#if os(macOS)`. Everything else in this target spawns and
// talks to a local subprocess, which only macOS can do, but these functions touch nothing
// beyond Foundation JSON containers and the ChatView model. Keeping them ungated is what
// lets the network transport (`acp-remote`, iOS and every other platform) map the SAME wire
// vocabulary through the SAME code as the stdio transport, instead of growing a second,
// silently diverging copy of the mapping.
//
// Moved here verbatim from ACPChatTransport in one behavior-preserving step; the existing
// ACPParsingTests pin them and were retargeted from `ACPChatTransport.` to `ACPWire.`.

import Foundation
import ChatView

/// Namespace for the stateless ACP payload parsing. Static, pure, unit-tested directly.
enum ACPWire {

    /// Joins the text out of an ACP content value - either one ContentBlock or an array
    /// of them. Non-text blocks (image / audio / resource) are noted rather than lost.
    static func contentText(_ content: Any?) -> String {
        if let block = content as? [String: Any] {
            return textOfBlock(block)
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.map(textOfBlock).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return ""
    }

    private static func textOfBlock(_ block: [String: Any]) -> String {
        switch block["type"] as? String {
        case "text":
            return (block["text"] as? String) ?? ""
        case "resource_link":
            let name = (block["name"] as? String) ?? (block["uri"] as? String) ?? "resource"
            return "[\(name)]"
        case "resource":
            let resource = block["resource"] as? [String: Any]
            let uri = (resource?["uri"] as? String) ?? "resource"
            return "[\(uri)]"
        case "image":
            return "[image]"
        case "audio":
            return "[audio]"
        default:
            return ""
        }
    }

    /// Maps an ACP tool_call payload onto ToolCallModel (defaults per the spec:
    /// kind "other", status "pending").
    static func parseToolCall(_ update: [String: Any]) -> ToolCallModel {
        let content = parseToolCallContent(update["content"])
        return ToolCallModel(
            id: (update["toolCallId"] as? String) ?? "acp-tool-unidentified",
            title: (update["title"] as? String) ?? "Tool call",
            kind: (update["kind"] as? String).flatMap(ToolCallModel.Kind.init(rawValue:)) ?? .other,
            status: (update["status"] as? String).flatMap(ToolCallModel.Status.init(rawValue:)) ?? .pending,
            contentText: content.text,
            diff: content.diff,
            rawInput: prettyJSON(update["rawInput"]),
            rawOutput: prettyJSON(update["rawOutput"])
        )
    }

    /// Maps an ACP tool_call_update payload; only the fields present on the wire are
    /// non-nil, so the store mutates just what changed.
    static func parseToolCallUpdate(_ update: [String: Any]) -> ToolCallUpdate {
        let content = update["content"] != nil ? parseToolCallContent(update["content"]) : (text: "", diff: nil)
        return ToolCallUpdate(
            id: (update["toolCallId"] as? String) ?? "acp-tool-unidentified",
            title: update["title"] as? String,
            kind: (update["kind"] as? String).flatMap(ToolCallModel.Kind.init(rawValue:)),
            status: (update["status"] as? String).flatMap(ToolCallModel.Status.init(rawValue:)),
            contentText: update["content"] != nil ? content.text : nil,
            diff: content.diff,
            rawInput: prettyJSON(update["rawInput"]),
            rawOutput: prettyJSON(update["rawOutput"])
        )
    }

    /// session/new result -> the session's selectable options. Parses OpenCode's
    /// generic `configOptions` (select-typed: model, mode, ...) and falls back to the
    /// spec's `modes` sketch ({ currentModeId, availableModes }). Internal for tests.
    static func parseConfigOptions(_ session: [String: Any]) -> [SessionConfigOption] {
        if let raw = session["configOptions"] as? [[String: Any]] {
            return raw.compactMap { option in
                guard let id = option["id"] as? String,
                      let current = option["currentValue"] as? String else {
                    return nil
                }
                if let type = option["type"] as? String, type != "select" {
                    return nil    // only selects are displayable (and, in part 3, settable)
                }
                let choices = (option["options"] as? [[String: Any]] ?? []).compactMap { choice -> SessionConfigOption.Choice? in
                    guard let value = choice["value"] as? String else {
                        return nil
                    }
                    return SessionConfigOption.Choice(value: value,
                                                      name: (choice["name"] as? String) ?? value,
                                                      description: choice["description"] as? String)
                }
                return SessionConfigOption(id: id,
                                           name: (option["name"] as? String) ?? id,
                                           category: option["category"] as? String,
                                           currentValue: current,
                                           options: choices)
            }
        }
        if let modes = session["modes"] as? [String: Any],
           let current = modes["currentModeId"] as? String {
            let choices = (modes["availableModes"] as? [[String: Any]] ?? []).compactMap { mode -> SessionConfigOption.Choice? in
                guard let id = mode["id"] as? String else {
                    return nil
                }
                return SessionConfigOption.Choice(value: id,
                                                  name: (mode["name"] as? String) ?? id,
                                                  description: mode["description"] as? String)
            }
            return [SessionConfigOption(id: "mode", name: "Mode", category: "mode",
                                        currentValue: current, options: choices)]
        }
        return []
    }

    /// `plan` update -> entries (spec shape: entries[{ content, priority, status }]).
    /// ACP plan entries carry no IDs, so identity is positional. Internal for tests.
    static func parsePlan(_ update: [String: Any]) -> [PlanEntry] {
        let raw = update["entries"] as? [[String: Any]] ?? []
        return raw.enumerated().compactMap { index, entry in
            guard let content = entry["content"] as? String else {
                return nil
            }
            let status = (entry["status"] as? String).flatMap(PlanEntry.Status.init(rawValue:)) ?? .pending
            return PlanEntry(id: index, content: content,
                             priority: entry["priority"] as? String, status: status)
        }
    }

    /// `available_commands_update` -> the agent's current slash commands
    /// (availableCommands: [{ name, description }]). Internal for tests.
    static func parseCommands(_ update: [String: Any]) -> [SlashCommand] {
        let raw = update["availableCommands"] as? [[String: Any]] ?? []
        return raw.compactMap { command in
            guard let name = command["name"] as? String, !name.isEmpty else {
                return nil
            }
            return SlashCommand(name: name, description: (command["description"] as? String) ?? "")
        }
    }

    /// `usage_update` -> UsageInfo (the shape OpenCode emits: used / size /
    /// cost { amount, currency }). Returns nil without a usable `used`. Internal for tests.
    static func parseUsage(_ update: [String: Any]) -> UsageInfo? {
        guard let used = (update["used"] as? NSNumber)?.intValue else {
            return nil
        }
        let cost = update["cost"] as? [String: Any]
        return UsageInfo(used: used,
                         size: (update["size"] as? NSNumber)?.intValue,
                         costAmount: (cost?["amount"] as? NSNumber)?.doubleValue,
                         costCurrency: cost?["currency"] as? String)
    }

    /// Splits a tool call's content array into its text (regular ContentBlocks) and the
    /// first diff. Terminal content is noted in the text (the live terminal panel is M5).
    private static func parseToolCallContent(_ content: Any?) -> (text: String, diff: ToolCallDiff?) {
        guard let entries = content as? [[String: Any]] else {
            return ("", nil)
        }
        var texts: [String] = []
        var diff: ToolCallDiff?
        for entry in entries {
            switch entry["type"] as? String {
            case "content":
                let text = contentText(entry["content"])
                if !text.isEmpty {
                    texts.append(text)
                }
            case "diff":
                if diff == nil, let path = entry["path"] as? String, let newText = entry["newText"] as? String {
                    diff = ToolCallDiff(path: path, oldText: entry["oldText"] as? String, newText: newText)
                }
            case "terminal":
                texts.append("[terminal output]")
            default:
                break
            }
        }
        return (texts.joined(separator: "\n\n"), diff)
    }

    static func prettyJSON(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let text = value as? String {
            return text
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}
