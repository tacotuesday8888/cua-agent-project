import AutopilotLLM

/// The tools the agent can invoke during a run.
public enum AgentTool: String, CaseIterable, Sendable {
    case readTree = "read_tree"
    case clickElement = "click_element"
    case setValue = "set_value"
    case scroll = "scroll"
    case pressKey = "key"
    case screenshot = "screenshot"
    case askUser = "ask_user"
    case done = "done"
}

/// The catalogue of tool definitions presented to the model.
public enum ToolCatalog {
    /// All tool definitions, in a stable order.
    public static let all: [ToolDefinition] = [
        readTree, clickElement, setValue, scroll, pressKey, screenshot, askUser, done
    ]

    static let readTree = ToolDefinition(
        name: AgentTool.readTree.rawValue,
        description: """
        Capture the current accessibility tree of the target app. Use this to \
        see the app's state before deciding the next action.
        """,
        inputSchema: [
            "type": "object",
            "properties": [:],
            "required": []
        ]
    )

    static let clickElement = ToolDefinition(
        name: AgentTool.clickElement.rawValue,
        description: """
        Press or activate a UI element — a button, link, menu item, row, or \
        checkbox. Provide the element id from the accessibility tree.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "element_id": [
                    "type": "string",
                    "description": "The id of the element to click, e.g. \"e12\"."
                ]
            ],
            "required": ["element_id"]
        ]
    )

    static let setValue = ToolDefinition(
        name: AgentTool.setValue.rawValue,
        description: """
        Set the text value of a text field or text area. This replaces the \
        field's current contents.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "element_id": [
                    "type": "string",
                    "description": "The id of the text field."
                ],
                "value": [
                    "type": "string",
                    "description": "The text to place into the field."
                ]
            ],
            "required": ["element_id", "value"]
        ]
    )

    static let scroll = ToolDefinition(
        name: AgentTool.scroll.rawValue,
        description: "Scroll the app, optionally within a specific scrollable element.",
        inputSchema: [
            "type": "object",
            "properties": [
                "element_id": [
                    "type": "string",
                    "description": "Optional id of the element to scroll within."
                ],
                "direction": [
                    "type": "string",
                    "enum": ["up", "down", "left", "right"],
                    "description": "The direction to scroll."
                ],
                "amount": [
                    "type": "integer",
                    "description": "Number of scroll steps (defaults to 3)."
                ]
            ],
            "required": ["direction"]
        ]
    )

    static let pressKey = ToolDefinition(
        name: AgentTool.pressKey.rawValue,
        description: """
        Send a keyboard key press to the app, e.g. "return", "escape", "tab". \
        Optionally include modifier keys.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "key": [
                    "type": "string",
                    "description": "Key name, e.g. \"return\", \"escape\", \"tab\", \"a\"."
                ],
                "modifiers": [
                    "type": "array",
                    "items": [
                        "type": "string",
                        "enum": ["command", "shift", "option", "control", "function"]
                    ],
                    "description": "Optional modifier keys held during the press."
                ]
            ],
            "required": ["key"]
        ]
    )

    static let screenshot = ToolDefinition(
        name: AgentTool.screenshot.rawValue,
        description: """
        Capture a screenshot of the app. Use only when the accessibility tree \
        is not enough to understand the UI, such as canvas or image content.
        """,
        inputSchema: [
            "type": "object",
            "properties": [:],
            "required": []
        ]
    )

    static let askUser = ToolDefinition(
        name: AgentTool.askUser.rawValue,
        description: """
        Ask the user a clarifying question when the task is ambiguous or needs \
        information only they can provide. Their answer is returned to you.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "question": [
                    "type": "string",
                    "description": "The question to ask the user."
                ]
            ],
            "required": ["question"]
        ]
    )

    static let done = ToolDefinition(
        name: AgentTool.done.rawValue,
        description: """
        Call this when the task is complete, or when it cannot be completed. \
        Provide a short summary of the outcome.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "A short summary of what was done."
                ]
            ],
            "required": ["summary"]
        ]
    )
}
