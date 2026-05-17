/// What an action is about to interact with.
///
/// The agent surfaces an `ActionTarget` *before* a click or keystroke fires, so
/// the UI can highlight the real element and an approval prompt can show what
/// is at stake before the user decides.
public struct ActionTarget: Sendable, Hashable, Codable {
    /// The app the action operates.
    public let appName: String
    /// The captured element's id, when the action targets a specific element.
    public let elementID: String?
    /// The element's accessibility role, e.g. "AXButton".
    public let role: String?
    /// The element's human-readable label.
    public let label: String?
    /// A one-line description of the action, e.g. Click the "Send" button.
    public let description: String
    /// The element's screen-space frame, for drawing a highlight over it.
    public let frame: ElementFrame?

    public init(
        appName: String,
        elementID: String? = nil,
        role: String? = nil,
        label: String? = nil,
        description: String,
        frame: ElementFrame? = nil
    ) {
        self.appName = appName
        self.elementID = elementID
        self.role = role
        self.label = label
        self.description = description
        self.frame = frame
    }
}
