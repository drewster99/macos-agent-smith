import Foundation
import MCP
import SwiftLLMKit

/// Bridges between the app's `AnyCodable` JSON representation (used for tool
/// schemas and parsed tool arguments) and the MCP SDK's `Value` type.
enum MCPValueConversion {
    /// Converts an MCP `Value` (e.g. a tool's `inputSchema`) into the `AnyCodable`
    /// JSON-Schema dictionary representation the rest of the app uses.
    static func anyCodable(from value: Value) -> AnyCodable {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .string(let s):
            return .string(s)
        case .data(_, let data):
            return .string(data.base64EncodedString())
        case .array(let arr):
            return .array(arr.map(anyCodable(from:)))
        case .object(let obj):
            return .dictionary(obj.mapValues(anyCodable(from:)))
        }
    }

    /// Converts a top-level MCP `Value` schema into the `[String: AnyCodable]`
    /// dictionary `AgentTool.parameters` expects. Non-object schemas are wrapped in
    /// a permissive object so the tool still presents a valid schema.
    static func parametersSchema(from value: Value?) -> [String: AnyCodable] {
        if let value, case .object(let obj) = value {
            return obj.mapValues(anyCodable(from:))
        }
        return ["type": .string("object"), "properties": .dictionary([:])]
    }

    /// Converts parsed tool-call arguments into the MCP `Value` map `callTool` expects.
    static func values(from arguments: [String: AnyCodable]) -> [String: Value] {
        arguments.mapValues(value(from:))
    }

    static func value(from anyCodable: AnyCodable) -> Value {
        switch anyCodable {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .string(let s):
            return .string(s)
        case .array(let arr):
            return .array(arr.map(value(from:)))
        case .dictionary(let dict):
            return .object(dict.mapValues(value(from:)))
        }
    }
}
