import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import AutopilotPerception

/// `AccessibilityTreeReader` maps the AX window it reads to a CoreGraphics
/// window number so screenshots target the right window. A title-only match
/// sends same-title windows (two documents, two browser windows) to whichever
/// the window list reports first — often the wrong one. Selection now prefers
/// the candidate whose bounds match the AX window's frame, falling back to
/// title only when no frame match is available.
private typealias Descriptor = AccessibilityTreeReader.CGWindowDescriptor

private func descriptor(
    number: UInt32,
    pid: pid_t = 42,
    layer: Int32 = 0,
    title: String? = nil,
    bounds: CGRect? = nil
) -> Descriptor {
    Descriptor(windowNumber: number, ownerPID: pid, layer: layer, title: title, bounds: bounds)
}

struct WindowFrameMatchTests {
    @Test func frameMatchDisambiguatesSameTitleWindows() {
        let windowA = descriptor(number: 10, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let windowB = descriptor(number: 20, title: "Doc", bounds: CGRect(x: 900, y: 100, width: 800, height: 600))
        // The AX window we read sits where window B is, even though A is listed
        // first and shares the title.
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [windowA, windowB],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 900, y: 100, width: 800, height: 600)
        )
        #expect(chosen == 20)
    }

    @Test func frameMatchWinsOverAnEarlierExactTitleMatch() {
        // Window A is an exact title match and listed first; frame still wins.
        let windowA = descriptor(number: 10, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let windowB = descriptor(number: 20, title: "Doc", bounds: CGRect(x: 500, y: 500, width: 400, height: 300))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [windowA, windowB],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 500, y: 500, width: 400, height: 300)
        )
        #expect(chosen == 20)
    }

    @Test func smallFrameDriftStillMatches() {
        // AX and CoreGraphics can disagree by a point or two; that must not
        // defeat the match.
        let window = descriptor(number: 7, title: "Doc", bounds: CGRect(x: 100, y: 100, width: 800, height: 600))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [window],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 101, y: 101, width: 799, height: 601)
        )
        #expect(chosen == 7)
    }

    @Test func closestCandidateWinsWhenSeveralAreNear() {
        let near = descriptor(number: 1, title: "Doc", bounds: CGRect(x: 100, y: 100, width: 800, height: 600))
        let nearer = descriptor(number: 2, title: "Doc", bounds: CGRect(x: 102, y: 100, width: 800, height: 600))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [near, nearer],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 103, y: 100, width: 800, height: 600)
        )
        #expect(chosen == 2)
    }

    @Test func farFrameFallsBackToTitle() {
        // No candidate is near the AX frame (e.g. the real window isn't in the
        // list yet), so selection falls back to the exact title match.
        let windowA = descriptor(number: 10, title: "Other", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let windowB = descriptor(number: 20, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [windowA, windowB],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 5000, y: 5000, width: 800, height: 600)
        )
        #expect(chosen == 20)
    }

    @Test func toleranceBoundaryFlipsFromFrameToTitle() {
        // The frame candidate is near the AX frame; the title candidate sits far
        // away. Crossing the tolerance must flip selection from one to the other.
        let frameCandidate = descriptor(number: 9, title: "Other", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let titleCandidate = descriptor(number: 5, title: "Doc", bounds: CGRect(x: 5000, y: 5000, width: 800, height: 600))
        // Origin drift of exactly the tolerance (10) on a single axis still
        // matches the frame candidate.
        let atBoundary = AccessibilityTreeReader.selectWindowNumber(
            from: [frameCandidate, titleCandidate],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 10, y: 0, width: 800, height: 600)
        )
        #expect(atBoundary == 9)
        // Just over the tolerance, no candidate matches the frame, so the exact
        // title match wins instead.
        let overBoundary = AccessibilityTreeReader.selectWindowNumber(
            from: [frameCandidate, titleCandidate],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 11, y: 0, width: 800, height: 600)
        )
        #expect(overBoundary == 5)
    }

    @Test func zeroSizedFrameIsIgnoredAndTitleMatchUsed() {
        // A failed AX frame read (zero size) must not poison selection.
        let windowA = descriptor(number: 10, title: "Other", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let windowB = descriptor(number: 20, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [windowA, windowB],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(chosen == 20)
    }

    @Test func candidateWithoutBoundsIsSkippedForFrameButKeptForTitle() {
        // The titled window has no bounds, so frame matching can't see it, but
        // the exact-title fallback still finds it.
        let boundless = descriptor(number: 30, title: "Doc", bounds: nil)
        let other = descriptor(number: 40, title: "Other", bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [boundless, other],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 5000, y: 5000, width: 800, height: 600)
        )
        #expect(chosen == 30)
    }
}

struct WindowTitleFallbackTests {
    @Test func nilFrameUsesExactTitle() {
        let windowA = descriptor(number: 10, title: "Other")
        let windowB = descriptor(number: 20, title: "Doc")
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [windowA, windowB],
            pid: 42,
            title: "Doc",
            frame: nil
        )
        #expect(chosen == 20)
    }

    @Test func emptyTitleFallsToFirstNamedWindow() {
        let unnamed = descriptor(number: 10, title: "")
        let named = descriptor(number: 20, title: "Inspector")
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [unnamed, named],
            pid: 42,
            title: nil,
            frame: nil
        )
        #expect(chosen == 20)
    }

    @Test func noNamedWindowFallsToFirstCandidate() {
        let first = descriptor(number: 10, title: nil)
        let second = descriptor(number: 20, title: "")
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [first, second],
            pid: 42,
            title: "Doc",
            frame: nil
        )
        #expect(chosen == 10)
    }
}

struct WindowCandidateFilterTests {
    @Test func windowsOfOtherProcessesAreIgnored() {
        let mine = descriptor(number: 10, pid: 42, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let theirs = descriptor(number: 20, pid: 99, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [theirs, mine],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        #expect(chosen == 10)
    }

    @Test func nonZeroLayerWindowsAreIgnored() {
        // Menus, tooltips, and palettes live above layer 0 and must not be
        // mistaken for the document window even on an exact frame match.
        let overlay = descriptor(number: 10, layer: 25, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let window = descriptor(number: 20, layer: 0, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: [overlay, window],
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        #expect(chosen == 20)
    }

    @Test func noCandidatesYieldsNil() {
        #expect(
            AccessibilityTreeReader.selectWindowNumber(
                from: [],
                pid: 42,
                title: "Doc",
                frame: CGRect(x: 0, y: 0, width: 10, height: 10)
            ) == nil
        )
        let onlyOthers = [descriptor(number: 10, pid: 99)]
        #expect(
            AccessibilityTreeReader.selectWindowNumber(
                from: onlyOthers,
                pid: 42,
                title: nil,
                frame: nil
            ) == nil
        )
    }
}

struct WindowDistanceTests {
    @Test func identicalFramesHaveZeroDistance() {
        let frame = CGRect(x: 12, y: 34, width: 567, height: 89)
        #expect(AccessibilityTreeReader.frameDistance(frame, frame) == 0)
    }

    @Test func distanceSumsOriginAndSizeDrift() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 1, y: 2, width: 103, height: 96)
        // |0-1| + |0-2| + |100-103| + |100-96| = 1 + 2 + 3 + 4
        #expect(AccessibilityTreeReader.frameDistance(a, b) == 10)
    }
}

struct WindowListParsingTests {
    @Test func parsesABoundsCarryingEntry() {
        let raw: [[String: Any]] = [[
            kCGWindowNumber as String: 77,
            kCGWindowOwnerPID as String: 42,
            kCGWindowLayer as String: 0,
            kCGWindowName as String: "Doc",
            kCGWindowBounds as String: ["X": 100, "Y": 200, "Width": 800, "Height": 600],
        ]]
        let parsed = AccessibilityTreeReader.parseWindowList(raw)
        #expect(parsed == [descriptor(
            number: 77,
            pid: 42,
            layer: 0,
            title: "Doc",
            bounds: CGRect(x: 100, y: 200, width: 800, height: 600)
        )])
    }

    @Test func dropsEntriesMissingAWindowNumber() {
        let raw: [[String: Any]] = [
            [kCGWindowOwnerPID as String: 42],
            [kCGWindowNumber as String: 5, kCGWindowOwnerPID as String: 42],
        ]
        let parsed = AccessibilityTreeReader.parseWindowList(raw)
        #expect(parsed.count == 1)
        #expect(parsed.first?.windowNumber == 5)
    }

    @Test func missingLayerDefaultsToZeroAndMissingBoundsIsNil() {
        let raw: [[String: Any]] = [[
            kCGWindowNumber as String: 5,
            kCGWindowOwnerPID as String: 42,
        ]]
        let parsed = AccessibilityTreeReader.parseWindowList(raw)
        #expect(parsed.first?.layer == 0)
        #expect(parsed.first?.bounds == nil)
        #expect(parsed.first?.title == nil)
    }

    @Test func parsedEntriesFlowThroughSelection() {
        let raw: [[String: Any]] = [
            [
                kCGWindowNumber as String: 1,
                kCGWindowOwnerPID as String: 42,
                kCGWindowLayer as String: 0,
                kCGWindowName as String: "Doc",
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 600],
            ],
            [
                kCGWindowNumber as String: 2,
                kCGWindowOwnerPID as String: 42,
                kCGWindowLayer as String: 0,
                kCGWindowName as String: "Doc",
                kCGWindowBounds as String: ["X": 900, "Y": 0, "Width": 800, "Height": 600],
            ],
        ]
        let chosen = AccessibilityTreeReader.selectWindowNumber(
            from: AccessibilityTreeReader.parseWindowList(raw),
            pid: 42,
            title: "Doc",
            frame: CGRect(x: 900, y: 0, width: 800, height: 600)
        )
        #expect(chosen == 2)
    }
}
