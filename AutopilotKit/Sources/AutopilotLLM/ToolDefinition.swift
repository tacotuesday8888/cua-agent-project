import AutopilotCore

/// A tool the model can call, with a JSON Schema describing its input.
public struct ToolDefinition: Sendable, Hashable {
    public let name: String
    public let description: String
    /// A JSON Schema object describing the tool's input parameters.
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
