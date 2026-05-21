import AutopilotCore
import Foundation

/// Normalizes model-supplied element references into snapshot ids such as `e12`.
///
/// The tool schema asks for integer `element_index` values, but real model
/// outputs occasionally come back as strings or as `element_id`. Keeping this
/// normalization in one place prevents risk classification, loop detection, and
/// execution from disagreeing about which element is being targeted.
enum ElementReference {
    static func optionalID(
        from input: JSONValue,
        primaryKey: String = "element_index",
        tool: AgentTool
    ) throws -> String? {
        try optionalID(from: input, primaryKey: primaryKey, toolName: tool.rawValue)
    }

    static func optionalID(
        from input: JSONValue,
        primaryKey: String = "element_index",
        toolName: String
    ) throws -> String? {
        if primaryKey == "element_index", let explicitID = input["element_id"] {
            return try normalizedID(explicitID, key: "element_id", toolName: toolName)
        }
        guard let raw = input[primaryKey] else { return nil }
        return try normalizedID(raw, key: primaryKey, toolName: toolName)
    }

    static func lenientID(
        from input: JSONValue,
        primaryKey: String = "element_index"
    ) -> String? {
        try? optionalID(from: input, primaryKey: primaryKey, toolName: primaryKey)
    }

    private static func normalizedID(
        _ value: JSONValue,
        key: String,
        toolName: String
    ) throws -> String {
        switch value {
        case .int(let index):
            return try normalizedIndex(index, key: key, toolName: toolName)
        case .string(let raw):
            return try normalizedString(raw, key: key, toolName: toolName)
        default:
            throw invalid(
                key: key,
                toolName: toolName,
                detail: "\(key) must be an integer or string element reference"
            )
        }
    }

    private static func normalizedString(
        _ raw: String,
        key: String,
        toolName: String
    ) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw invalid(key: key, toolName: toolName, detail: "\(key) must not be empty")
        }
        if let index = Int(trimmed) {
            return try normalizedIndex(index, key: key, toolName: toolName)
        }
        if trimmed.hasPrefix("e") {
            return trimmed
        }
        throw invalid(
            key: key,
            toolName: toolName,
            detail: "\(key) must be an integer or element id like e12"
        )
    }

    private static func normalizedIndex(
        _ index: Int,
        key: String,
        toolName: String
    ) throws -> String {
        guard index >= 0 else {
            throw invalid(key: key, toolName: toolName, detail: "\(key) must not be negative")
        }
        return "e\(index)"
    }

    private static func invalid(
        key: String,
        toolName: String,
        detail: String
    ) -> AgentError {
        AgentError.invalidToolInput(tool: toolName, detail: detail)
    }
}
