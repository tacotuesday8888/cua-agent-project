import AppKit

/// Describes a screen's notch and the window frames the notch UI uses.
///
/// On a notched Mac the panel aligns to the physical notch; on a non-notch Mac
/// it falls back to a centered pill at the top of the screen.
public struct NotchGeometry: Sendable {
    /// The full frame of the screen this geometry describes.
    public let screenFrame: CGRect
    /// Whether the screen has a physical notch.
    public let hasNotch: Bool
    /// The physical notch's size (zero on non-notch screens).
    public let notchSize: CGSize

    /// Build geometry for a screen (defaults to the main screen).
    @MainActor
    public init(screen: NSScreen? = NSScreen.main) {
        guard let screen else {
            screenFrame = .zero
            hasNotch = false
            notchSize = .zero
            return
        }
        screenFrame = screen.frame

        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchSize = CGSize(width: max(right.minX - left.maxX, 0), height: topInset)
        } else {
            hasNotch = false
            notchSize = .zero
        }
    }

    /// Size of the collapsed panel — the physical notch, or a fallback pill.
    public var collapsedSize: CGSize {
        hasNotch ? notchSize : CGSize(width: 180, height: 32)
    }

    /// The collapsed window frame: centered, flush with the top of the screen.
    public var collapsedFrame: CGRect {
        frame(for: collapsedSize)
    }

    /// An expanded window frame with the given content size.
    public func expandedFrame(width: CGFloat = 420, height: CGFloat) -> CGRect {
        frame(for: CGSize(width: max(width, collapsedSize.width), height: height))
    }

    /// Center `size` horizontally and pin it to the top of the screen.
    private func frame(for size: CGSize) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
