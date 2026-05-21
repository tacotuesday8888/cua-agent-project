import ApplicationServices
import AutopilotCore
import CoreGraphics
import Foundation
@testable import AutopilotMac

/// A recording `MacActuating` for tests.
///
/// It never touches `AXUIElement` — it records element-id keys — and lets each
/// operation be scripted to throw. Marked `@unchecked Sendable` because tests
/// hold it across the `MacComputer` actor's `await` boundary; the actor mutates
/// it during a call and the test reads it afterward, so access is serialized by
/// the `await` and the recording state is additionally lock-guarded.
final class MockActuator: MacActuating, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedElementKeys: [String] = []
    private var recordedTurnIdentifier: Int?

    /// Scriptable failures. Set before the call under test.
    var pressError: Error?
    var focusError: Error?
    var clickError: Error?
    var setValueError: Error?
    var performError: Error?
    /// A resolution failure (`ComputerControlError`) raised by element-keyed ops
    /// before the AX action, to drive resolution-error tests.
    var resolutionError: Error?

    /// The actuation calls received, in order.
    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    /// The element-id keys from the most recent `updateElements`.
    var lastElementKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedElementKeys
    }

    /// The turn id from the most recent `updateElements`.
    var lastTurnIdentifier: Int? {
        lock.lock(); defer { lock.unlock() }
        return recordedTurnIdentifier
    }

    private func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        recordedCalls.append(entry)
    }

    func updateElements(_ elements: [String: AXUIElement], turnIdentifier: Int?) {
        lock.lock(); defer { lock.unlock() }
        recordedElementKeys = elements.keys.sorted()
        recordedTurnIdentifier = turnIdentifier
    }

    func press(elementID: String) throws {
        record("press:\(elementID)")
        if let resolutionError { throw resolutionError }
        if let pressError { throw pressError }
    }

    func focus(elementID: String) throws {
        record("focus:\(elementID)")
        if let resolutionError { throw resolutionError }
        if let focusError { throw focusError }
    }

    func setValue(elementID: String, to value: String) throws {
        record("setValue:\(elementID)=\(value)")
        if let resolutionError { throw resolutionError }
        if let setValueError { throw setValueError }
    }

    func perform(action: String, elementID: String) throws {
        record("perform:\(elementID):\(action)")
        if let resolutionError { throw resolutionError }
        if let performError { throw performError }
    }

    func click(at point: CGPoint) throws {
        record("click:\(Int(point.x)),\(Int(point.y))")
        if let clickError { throw clickError }
    }

    func typeText(_ text: String) throws {
        record("typeText:\(text)")
    }

    func pressKey(_ key: KeyPress) throws {
        record("key:\(key.key)")
    }

    func scroll(direction: ScrollDirection, amount: Int, at point: CGPoint?) throws {
        let suffix = point.map { ":\(Int($0.x)),\(Int($0.y))" } ?? ""
        record("scroll:\(direction.rawValue):\(amount)\(suffix)")
    }

    func drag(from start: CGPoint, to end: CGPoint) throws {
        record("drag:\(Int(start.x)),\(Int(start.y))->\(Int(end.x)),\(Int(end.y))")
    }
}
