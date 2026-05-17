import AutopilotCore
import CoreGraphics
import Testing
@testable import AutopilotAction

struct KeyCodesTests {
    @Test func resolvesCommonControlKeys() {
        for key in ["return", "tab", "space", "escape", "delete"] {
            #expect(KeyCodes.code(for: key) != nil, "\(key) should resolve")
        }
    }

    @Test func resolvesArrowKeysAndAliases() {
        let up = KeyCodes.code(for: "up")
        #expect(up != nil)
        #expect(KeyCodes.code(for: "uparrow") == up)
        #expect(KeyCodes.code(for: "arrowup") == up)
        // The KeyPress doc comment offers "downArrow" as an example — it must work.
        #expect(KeyCodes.code(for: "downArrow") == KeyCodes.code(for: "down"))
    }

    @Test func resolvesNavigationAndFunctionKeys() {
        for key in ["home", "end", "pageup", "pagedown"] {
            #expect(KeyCodes.code(for: key) != nil, "\(key) should resolve")
        }
        for number in 1...12 {
            #expect(KeyCodes.code(for: "f\(number)") != nil, "f\(number) should resolve")
        }
    }

    @Test func aliasesShareTheirCanonicalCode() {
        #expect(KeyCodes.code(for: "enter") == KeyCodes.code(for: "return"))
        #expect(KeyCodes.code(for: "esc") == KeyCodes.code(for: "escape"))
        #expect(KeyCodes.code(for: "del") == KeyCodes.code(for: "delete"))
    }

    @Test func matchingIgnoresCaseAndSpacing() {
        let pageUp = KeyCodes.code(for: "pageup")
        #expect(pageUp != nil)
        #expect(KeyCodes.code(for: "Page Up") == pageUp)
        #expect(KeyCodes.code(for: "page-up") == pageUp)
        #expect(KeyCodes.code(for: "PAGE_UP") == pageUp)
    }

    @Test func unknownKeyReturnsNil() {
        #expect(KeyCodes.code(for: "hyperspace") == nil)
        #expect(KeyCodes.code(for: "") == nil)
    }

    @Test func riskClassifierDeleteKeysAllResolve() {
        // RiskClassifier flags command + these keys as destructive; each must
        // also resolve here, or press_key would fail before the gate runs.
        for key in ["delete", "backspace", "forwarddelete"] {
            #expect(KeyCodes.code(for: key) != nil, "\(key) should resolve")
        }
    }

    @Test func eventFlagsMapFromModifiers() {
        #expect(CGEventFlags(modifiers: []).isEmpty)
        #expect(CGEventFlags(modifiers: [.command]).contains(.maskCommand))
        let combo = CGEventFlags(modifiers: [.command, .shift])
        #expect(combo.contains(.maskCommand))
        #expect(combo.contains(.maskShift))
    }
}
