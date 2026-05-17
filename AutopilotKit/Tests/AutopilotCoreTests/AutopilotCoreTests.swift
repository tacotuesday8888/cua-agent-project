import Foundation
import Testing
@testable import AutopilotCore

struct JSONValueTests {
    @Test func literalConstruction() {
        let value: JSONValue = [
            "name": "Autopilot",
            "count": 3,
            "on": true,
            "tags": ["a", "b"]
        ]
        #expect(value["name"]?.stringValue == "Autopilot")
        #expect(value["count"]?.intValue == 3)
        #expect(value["on"]?.boolValue == true)
        #expect(value["tags"]?.arrayValue?.count == 2)
        #expect(value["missing"] == nil)
    }

    @Test func codableRoundTrip() throws {
        let original: JSONValue = [
            "type": "object",
            "nested": ["x": 1, "y": [true, false]],
            "nothing": nil
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test func numberAccessors() {
        #expect(JSONValue.int(5).doubleValue == 5.0)
        #expect(JSONValue.double(2.0).intValue == 2)
        #expect(JSONValue.string("x").intValue == nil)
    }
}

struct UITreeTests {
    private func sampleTree() -> UITreeSnapshot {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Search", value: "")
        let button = UIElement(id: "e3", role: "AXButton", label: "Go")
        let root = UIElement(id: "e1", role: "AXWindow", label: "Main",
                             children: [field, button])
        return UITreeSnapshot(appName: "TestApp", windowTitle: "Main", root: root)
    }

    @Test func findsElementByID() {
        let tree = sampleTree()
        #expect(tree.element(id: "e3")?.label == "Go")
        #expect(tree.element(id: "missing") == nil)
    }

    @Test func flattenIncludesEveryElement() {
        #expect(sampleTree().root.flattened.count == 3)
    }

    @Test func settingValueReplacesOnlyTheTarget() {
        let original = UIElement(
            id: "e2",
            role: "AXTextField",
            subrole: "AXSearchField",
            identifier: "search-field",
            label: "Search",
            value: "",
            isValueSettable: true,
            actions: ["AXPress"]
        )
        let updated = original.settingValue("jazz", forID: "e2")

        #expect(updated.value == "jazz")
        #expect(updated.subrole == "AXSearchField")
        #expect(updated.identifier == "search-field")
        #expect(updated.isValueSettable)
        #expect(updated.actions == ["AXPress"])
    }
}

struct UITreeRendererTests {
    @Test func compactTextShowsLabelsValuesAndState() {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Search",
                              value: "jazz", isFocused: true)
        let root = UIElement(id: "e1", role: "AXWindow", children: [field])
        let snapshot = UITreeSnapshot(appName: "Music", windowTitle: "Library", root: root)

        let text = UITreeRenderer.compactText(snapshot)
        #expect(text.contains("App: Music"))
        #expect(text.contains("Window: Library"))
        #expect(text.contains("[2]"))
        #expect(text.contains("\"Search\""))
        #expect(text.contains("value:\"jazz\""))
        #expect(text.contains("focused"))
    }

    @Test func compactTextShowsSnapshotAndElementMetadata() {
        let popup = UIElement(
            id: "e2",
            role: "AXPopUpButton",
            subrole: "AXUnknown",
            identifier: "account-picker",
            label: "Account",
            isValueSettable: true,
            actions: ["AXPress", "AXShowMenu"]
        )
        let root = UIElement(id: "e1", role: "AXWindow", children: [popup])
        let snapshot = UITreeSnapshot(
            appName: "Mail",
            processIdentifier: 123,
            windowTitle: "Inbox",
            windowIdentifier: 456,
            turnIdentifier: 7,
            root: root
        )

        let text = UITreeRenderer.compactText(snapshot)
        #expect(text.contains("Window ID: 456"))
        #expect(text.contains("Turn: 7"))
        #expect(text.contains("subrole:AXUnknown"))
        #expect(text.contains("identifier:account-picker"))
        #expect(text.contains("settable"))
        #expect(text.contains("actions:AXShowMenu"))
    }

    @Test func compactTextRespectsElementLimit() {
        let children = (0..<50).map {
            UIElement(id: "e\($0)", role: "AXButton", label: "Button \($0)")
        }
        let root = UIElement(id: "root", role: "AXWindow", children: children)
        let snapshot = UITreeSnapshot(appName: "App", root: root)

        let text = UITreeRenderer.compactText(snapshot, maxElements: 10)
        #expect(text.contains("truncated"))
    }
}
