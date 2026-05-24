import AutopilotLLM

/// The tools the agent can invoke during a run.
///
/// The computer-control surface follows the proven 9-tool shape used by
/// Open Computer Use / Cua. `ask_user` and `done` are Mac Autopilot
/// orchestration tools layered around that driver surface.
public enum AgentTool: String, CaseIterable, Sendable {
    case listApps = "list_apps"
    case getAppState = "get_app_state"
    case click = "click"
    case scroll = "scroll"
    case typeText = "type_text"
    case pressKey = "press_key"
    case setValue = "set_value"
    case drag = "drag"
    case performSecondaryAction = "perform_secondary_action"
    case askUser = "ask_user"
    case proposeMemory = "propose_memory"
    case proposeWorkflow = "propose_workflow"
    case done = "done"
}

/// The catalogue of tool definitions presented to the model.
public enum ToolCatalog {
    /// All tool definitions, in a stable order.
    public static let all: [ToolDefinition] = [
        listApps,
        getAppState,
        click,
        scroll,
        typeText,
        pressKey,
        setValue,
        drag,
        performSecondaryAction,
        askUser,
        proposeMemory,
        proposeWorkflow,
        done
    ]

    static let listApps = ToolDefinition(
        name: AgentTool.listApps.rawValue,
        description: """
        List the apps available to the computer-use driver. In Mac Autopilot's \
        current single-app mode, this returns the selected target app.
        """,
        inputSchema: [
            "type": "object",
            "properties": [:],
            "required": []
        ]
    )

    static let getAppState = ToolDefinition(
        name: AgentTool.getAppState.rawValue,
        description: """
        Capture the current state of the target app. Returns the accessibility \
        tree, and optionally a target-window screenshot when visual content is \
        needed.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "include_screenshot": [
                    "type": "boolean",
                    "description": "Set true only when the accessibility tree is insufficient."
                ]
            ],
            "required": []
        ]
    )

    static let click = ToolDefinition(
        name: AgentTool.click.rawValue,
        description: """
        Press or activate a UI element, such as a button, link, row, menu item, \
        or checkbox. Provide the element_index from get_app_state.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "element_index": [
                    "type": "integer",
                    "description": "The element index from the app state, e.g. 12."
                ]
            ],
            "required": ["element_index"]
        ]
    )

    static let scroll = ToolDefinition(
        name: AgentTool.scroll.rawValue,
        description: "Scroll the target app, optionally within a specific scrollable element.",
        inputSchema: [
            "type": "object",
            "properties": [
                "element_index": [
                    "type": "integer",
                    "description": "Optional element index to scroll within."
                ],
                "direction": [
                    "type": "string",
                    "enum": ["up", "down", "left", "right"],
                    "description": "The direction to scroll."
                ],
                "amount": [
                    "type": "integer",
                    "description": "Number of scroll steps. Defaults to 3."
                ]
            ],
            "required": ["direction"]
        ]
    )

    static let typeText = ToolDefinition(
        name: AgentTool.typeText.rawValue,
        description: """
        Type text into the target app's currently-focused editable element. If \
        element_index is provided, the driver first activates that element.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "element_index": [
                    "type": "integer",
                    "description": "Optional editable element to focus before typing."
                ],
                "text": [
                    "type": "string",
                    "description": "The text to type."
                ]
            ],
            "required": ["text"]
        ]
    )

    static let pressKey = ToolDefinition(
        name: AgentTool.pressKey.rawValue,
        description: """
        Send a keyboard key press to the target app, e.g. "return", "escape", \
        or "tab". Optionally include modifier keys.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "key": [
                    "type": "string",
                    "description": "Key name: a letter or digit, or one of return, enter, tab, space, escape, delete, forwarddelete, up, down, left, right, home, end, pageup, pagedown, f1-f12."
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

    static let setValue = ToolDefinition(
        name: AgentTool.setValue.rawValue,
        description: """
        Set the text value of a text field or text area. This replaces the \
        field's current contents.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "element_index": [
                    "type": "integer",
                    "description": "The editable element index from the app state."
                ],
                "value": [
                    "type": "string",
                    "description": "The text to place into the field."
                ]
            ],
            "required": ["element_index", "value"]
        ]
    )

    static let drag = ToolDefinition(
        name: AgentTool.drag.rawValue,
        description: "Drag from one captured element to another captured element.",
        inputSchema: [
            "type": "object",
            "properties": [
                "from_element_index": [
                    "type": "integer",
                    "description": "The element index where the drag starts."
                ],
                "to_element_index": [
                    "type": "integer",
                    "description": "The element index where the drag ends."
                ]
            ],
            "required": ["from_element_index", "to_element_index"]
        ]
    )

    static let performSecondaryAction = ToolDefinition(
        name: AgentTool.performSecondaryAction.rawValue,
        description: """
        Perform a non-primary accessibility action exposed by an element, such \
        as AXShowMenu or AXIncrement. Use only actions shown in get_app_state.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "element_index": [
                    "type": "integer",
                    "description": "The element index from the app state."
                ],
                "action": [
                    "type": "string",
                    "description": "The exact AX action name to perform."
                ]
            ],
            "required": ["element_index", "action"]
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

    static let proposeMemory = ToolDefinition(
        name: AgentTool.proposeMemory.rawValue,
        description: """
        Propose a durable fact or preference about the user that would help on \
        future tasks. The user approves or skips it; if approved it is saved to \
        local memory. Only propose stable, reusable preferences — never \
        task-specific details, passwords, or anything sensitive.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "text": [
                    "type": "string",
                    "description": "The fact or preference, as a short statement."
                ],
                "scope": [
                    "type": "string",
                    "enum": ["global", "app", "contact"],
                    "description": "global: always relevant. app: one app. contact: one person."
                ],
                "scope_value": [
                    "type": "string",
                    "description": "The app or contact name. Required when scope is app or contact."
                ]
            ],
            "required": ["text", "scope"]
        ]
    )

    static let proposeWorkflow = ToolDefinition(
        name: AgentTool.proposeWorkflow.rawValue,
        description: """
        Propose saving the current task as a reusable workflow, after you have \
        completed it successfully and it is the kind of task the user would run \
        again. The user approves or skips it; if approved it is saved locally. \
        Use {{slot}} placeholders in the goal for the parts that change per run \
        (for example "Email {{recipient}} the weekly report"). The optional \
        recipe is a few short hints for next time — never recorded clicks, \
        passwords, or one-off values.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A short, human-facing name for the workflow."
                ],
                "goal_template": [
                    "type": "string",
                    "description": "The reusable goal, with {{slot}} placeholders for variable parts."
                ],
                "recipe": [
                    "type": "string",
                    "description": "Optional short hints for re-runs. Guidance only, never sensitive values."
                ]
            ],
            "required": ["name", "goal_template"]
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
