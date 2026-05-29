import AutopilotCore
import Foundation

/// Opt-in diagnostic sink for developer trajectory recording.
///
/// Unlike run history, trace output may contain task text, target labels, and
/// other screen-derived details. Use it only for explicit validation runs.
public protocol AgentRunRecording: Sendable {
    func record(_ event: AgentTraceEvent)
    func recordArtifact(data: Data, suggestedFilename: String) -> String?
}

public extension AgentRunRecording {
    func recordArtifact(data: Data, suggestedFilename: String) -> String? { nil }
}

/// One JSONL trajectory event emitted during a run.
public struct AgentTraceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case runStarted = "run_started"
        case prepared
        case diagnostics
        case thinking
        case observedTree = "observed_tree"
        case tokenUsage = "token_usage"
        case message
        case memoryRecalled = "memory_recalled"
        case willPerform = "will_perform"
        case awaitingConfirmation = "awaiting_confirmation"
        case confirmationDenied = "confirmation_denied"
        case performed
        case actionFailed = "action_failed"
        case actionVerified = "action_verified"
        case askedUser = "asked_user"
        case memoryProposed = "memory_proposed"
        case memoryStored = "memory_stored"
        case workflowProposed = "workflow_proposed"
        case workflowSaved = "workflow_saved"
        case storageFailed = "storage_failed"
        case screenshotCaptured = "screenshot_captured"
        case finished
        case failed
        case stopped
    }

    public var timestamp: Date
    public var kind: Kind
    public var task: String?
    public var appName: String?
    public var summary: String?
    public var status: String?
    public var tool: String?
    public var riskTier: String?
    public var target: ActionTarget?
    public var reason: String?
    public var question: String?
    public var elementCount: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var diagnosticSummary: String?
    public var artifactPath: String?
    public var verification: ActionVerificationResult?

    public init(
        timestamp: Date = Date(),
        kind: Kind,
        task: String? = nil,
        appName: String? = nil,
        summary: String? = nil,
        status: String? = nil,
        tool: String? = nil,
        riskTier: String? = nil,
        target: ActionTarget? = nil,
        reason: String? = nil,
        question: String? = nil,
        elementCount: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        diagnosticSummary: String? = nil,
        artifactPath: String? = nil,
        verification: ActionVerificationResult? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.task = task
        self.appName = appName
        self.summary = summary
        self.status = status
        self.tool = tool
        self.riskTier = riskTier
        self.target = target
        self.reason = reason
        self.question = question
        self.elementCount = elementCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.diagnosticSummary = diagnosticSummary
        self.artifactPath = artifactPath
        self.verification = verification
    }

    public init(agentEvent event: AgentEvent) {
        switch event {
        case .started(let task):
            self.init(kind: .runStarted, task: task)
        case .prepared(let summary):
            self.init(kind: .prepared, summary: summary)
        case .diagnostics(let diagnostics):
            self.init(
                kind: .diagnostics,
                appName: diagnostics.appName,
                diagnosticSummary: diagnostics.summary
            )
        case .thinking:
            self.init(kind: .thinking)
        case .observedTree(let elementCount):
            self.init(kind: .observedTree, elementCount: elementCount)
        case .tokenUsage(let inputTokens, let outputTokens):
            self.init(
                kind: .tokenUsage,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        case .message(let message):
            self.init(kind: .message, summary: message)
        case .memoryRecalled(let items):
            self.init(kind: .memoryRecalled, summary: "\(items.count) item(s)")
        case .willPerform(let tool, let target, let tier):
            self.init(
                kind: .willPerform,
                appName: target.appName,
                summary: target.description,
                tool: tool.rawValue,
                riskTier: tier.rawValue,
                target: target
            )
        case .awaitingConfirmation(let request):
            self.init(
                kind: .awaitingConfirmation,
                appName: request.appName,
                summary: request.summary,
                riskTier: request.tier.rawValue,
                target: request.target
            )
        case .confirmationDenied(let summary):
            self.init(kind: .confirmationDenied, summary: summary)
        case .performed(let tool, let summary):
            self.init(kind: .performed, summary: summary, tool: tool.rawValue)
        case .actionFailed(let tool, let reason):
            self.init(kind: .actionFailed, tool: tool.rawValue, reason: reason)
        case .askedUser(let question, _):
            self.init(kind: .askedUser, question: question)
        case .memoryProposed(let proposal):
            self.init(kind: .memoryProposed, summary: proposal.text)
        case .memoryStored(let item):
            self.init(kind: .memoryStored, summary: item.text)
        case .workflowProposed(let proposal):
            self.init(kind: .workflowProposed, summary: proposal.name)
        case .workflowSaved(let name):
            self.init(kind: .workflowSaved, summary: name)
        case .storageFailed(let message):
            self.init(kind: .storageFailed, reason: message)
        case .finished(let summary):
            self.init(kind: .finished, summary: summary, status: "completed")
        case .failed(let reason):
            self.init(kind: .failed, status: "failed", reason: reason)
        case .stopped:
            self.init(kind: .stopped, status: "stopped")
        }
    }
}

/// Synchronous JSONL trace writer for opt-in validation runs.
public final class JSONLAgentRunRecorder: AgentRunRecording, @unchecked Sendable {
    public let directory: URL
    public let traceURL: URL

    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(directory: URL) throws {
        self.directory = directory
        self.traceURL = directory.appending(path: "trace.jsonl")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: traceURL.path) {
            FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        }
    }

    public func record(_ event: AgentTraceEvent) {
        lock.lock()
        defer { lock.unlock() }
        do {
            var data = try encoder.encode(event)
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: traceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    public func recordArtifact(data: Data, suggestedFilename: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let filename = sanitizedFilename(suggestedFilename)
        let url = directory.appending(path: filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var output = ""
        var previousWasDash = false
        for scalar in lowered.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "-"
            if isAllowed {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "artifact.bin" : trimmed
    }
}
