import AutopilotLLM

/// The running conversation an `AgentSession` sends to the model.
///
/// `Transcript` owns the message list and one invariant: the context stays
/// bounded. A run reads a full accessibility tree after every action, so
/// without pruning a long task would carry every screen it ever saw. The
/// transcript keeps only the most recent observations verbatim and replaces
/// older ones with a short placeholder — while never breaking the
/// tool_use/tool_result pairing the providers require.
struct Transcript {
    /// The conversation sent to the model, oldest first.
    private(set) var messages: [LLMMessage] = []

    /// The task text, kept so a pruned initial message can be rebuilt.
    private var task = ""
    /// The controlled app's name, used in the seeded messages.
    private var appName = ""
    /// How many recent UI-tree observations stay verbatim.
    private var liveObservationWindow = 3
    /// Tool-use ids whose results embed a full UI-tree render, so the
    /// compactor can find and prune the stale ones.
    private var observationToolUseIDs: Set<String> = []

    /// Placeholder left where a stale UI-tree observation was pruned.
    static let prunedObservationNote = """
    [Earlier app state omitted to keep context small. Call get_app_state to \
    re-read the current screen.]
    """

    /// Seed the transcript with the task and the first observed tree.
    mutating func begin(
        task: String,
        appName: String,
        initialTreeText: String,
        liveObservationWindow: Int
    ) {
        self.task = task
        self.appName = appName
        self.liveObservationWindow = max(1, liveObservationWindow)
        messages = [
            LLMMessage(role: .user, content: [
                .text("""
                Task: \(task)

                Current state of \(appName):
                \(initialTreeText)
                """)
            ])
        ]
    }

    /// Append the model's assistant message.
    mutating func appendAssistant(_ content: [LLMContentBlock]) {
        messages.append(LLMMessage(role: .assistant, content: content))
    }

    /// Append a user message carrying this step's tool results.
    mutating func appendToolResults(_ content: [LLMContentBlock]) {
        messages.append(LLMMessage(role: .user, content: content))
    }

    /// Record that the result of `toolUseID` embeds a full UI-tree render, so
    /// the compactor may prune it once newer observations arrive.
    mutating func recordObservation(toolUseID: String) {
        observationToolUseIDs.insert(toolUseID)
    }

    /// Replace all but the most recent few UI-tree observations with a short
    /// placeholder. Tool-use/tool-result pairing is kept intact — only the
    /// stale result *content* is shrunk.
    mutating func compact() {
        // Observation carriers, oldest first: the initial task message (which
        // embeds the first tree), then every tool result that embedded a tree.
        var carriers: [(message: Int, block: Int?)] = [(0, nil)]
        for (messageIndex, message) in messages.enumerated() {
            for (blockIndex, block) in message.content.enumerated() {
                guard case .toolResult(let result) = block,
                      observationToolUseIDs.contains(result.toolUseID) else {
                    continue
                }
                carriers.append((messageIndex, blockIndex))
            }
        }
        guard carriers.count > liveObservationWindow else { return }

        for carrier in carriers.dropLast(liveObservationWindow) {
            guard let blockIndex = carrier.block else {
                messages[0] = LLMMessage(role: .user, content: [
                    .text("Task: \(task)\n\n\(Self.prunedObservationNote)")
                ])
                continue
            }
            messages[carrier.message] = stubbingObservation(
                at: blockIndex,
                in: messages[carrier.message]
            )
        }
    }

    /// Return a copy of `message` with the tool-result block at `index` shrunk
    /// to the prune placeholder, preserving its tool-use id and error flag.
    private func stubbingObservation(at index: Int, in message: LLMMessage) -> LLMMessage {
        var content = message.content
        guard case .toolResult(let result) = content[index] else { return message }
        content[index] = .toolResult(ToolResult(
            toolUseID: result.toolUseID,
            content: [.text(Self.prunedObservationNote)],
            isError: result.isError
        ))
        return LLMMessage(role: message.role, content: content)
    }
}
