// Sources/ACPBridge/BridgeJSON.swift
//
// Sendable carriers for parsed JSON.
//
// The bridge is a JSON-RPC proxy, so it moves `[String: Any]` payloads across concurrency
// boundaries constantly - into the Task that runs a turn, into the Task that awaits a
// permission answer. `[String: Any]` is not Sendable (Any is not), and Swift 6 is right to
// object in general. It is safe HERE for a specific, checkable reason: every one of these
// dictionaries is the immediate product of `JSONSerialization.jsonObject`, is never mutated
// after it is boxed, and is handed to exactly one consumer. There is no second reference for
// a race to be had with.
//
// Keeping the unchecked-ness in two named types rather than scattering `@unchecked Sendable`
// over the classes that pass them means the compiler still checks everything else.

#if os(macOS)

import Foundation

/// A parsed JSON object crossing a concurrency boundary.
package struct JSONPayload: @unchecked Sendable {
    package let value: [String: Any]

    package init(_ value: [String: Any]) {
        self.value = value
    }
}

/// A JSON-RPC message id, which the spec allows to be a string, a number, or absent. It is
/// echoed back verbatim and never inspected, so its dynamic type does not matter to us.
package struct JSONRPCID: @unchecked Sendable {
    package let value: Any?

    package init(_ value: Any?) {
        self.value = value
    }
}

#endif
