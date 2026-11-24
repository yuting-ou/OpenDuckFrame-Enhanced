import Foundation
import AppKit

private enum EnhancementText {
    static func t(_ english: String, _ chinese: String) -> String { english }
}

private struct EnhancementProfile {
    var sourceKind = "window"
}

private final class Button {
    var isHidden = false
    var isEnabled = true
    var title = ""
    var toolTip: String?
}

private final class Label {
    var stringValue = ""
    var textColor: NSColor?
}

private final class EnhancementCountdown {
    var active = false
    var remaining = 0
    func cancel() { active = false }
}

private final class Capture {
    var running = true
    var paused = false
    var stops = 0
    func stop() { stops += 1; running = false }
}

private final class Processor {
    var stops = 0
    func stop() { stops += 1 }
}

private final class InputRouter {
    var stops = 0
    func stop(reason: String) { stops += 1 }
}

private final class LiveApply {
    var cancellations = 0
    func cancel() { cancellations += 1 }
}

private final class R7Health {
    var resets = 0
    func reset() { resets += 1 }
}

private final class FilePlayer {
    var cancellations = 0
    var commits = 0
    func workbenchCancelFileOutput() { cancellations += 1 }
    @discardableResult
    func workbenchCommitFilePlan(interpolation: Bool, rife: Bool, cadence: Int, numerator: Int, denominator: Int, scaler: Bool) -> Bool {
        commits += 1
        return true
    }
}

private class Panel {
    var orderOuts = 0
    func orderOut(_ sender: Any?) { orderOuts += 1 }
}

private final class TargetPanel: Panel {
    var viewerKeyboard = false
}

private final class OutputPreview {
    var refreshes = 0
    func refreshVisibilitySnapshot() { refreshes += 1 }
}

private final class WindowSelectionList {
    var reloads = 0
    func reloadWindows() { reloads += 1 }
}

private final class SourceSwitchHarness: @unchecked Sendable {
    var profile = EnhancementProfile()
    var sourceKindControl = (selectedSegment: 0, unused: 0)
    var capture = Capture()
    var processor = Processor()
    var inputRouter: InputRouter? = InputRouter()
    var interactionArmed = true
    var r7Health = R7Health()
    var r7LastHealthAt = 0.0
    var r7Visibility = ""
    var countdown = EnhancementCountdown()
    var cancellations = 0
    var delayedWindowSelection = false
    var startImmediatelyAfterPreparation = false
    var applyingFileSettings = false
    var fileOutputToken = 0
    var filePlayer: FilePlayer? = FilePlayer()
    var fileApplied: Int?
    var filePreparing = false
    var hasPendingFormChanges = false
    var hasSelectedSource = true
    var sourceWindowPreparing = false
    var pendingApply: Int?
    var pendingSourceGeneration: UInt64?
    var liveApply = LiveApply()
    var viewerActive = false
    var viewerFollowOverride = false
    var viewerReturnPID: Int?
    var viewerControlsPanel: Panel?
    var outputWindow: Panel?
    var outputWarmupToken = 0
    var outputMinimumCaptureHost = 0
    var targetHUD: Panel?
    var targetCountdownHUD: Panel?
    var outputPreview = OutputPreview()
    var lastStats: [String: Any] = [:]
    var lastStatsReceipt = 0
    var statsLabel = Label()
    var budgetLabel = Label()
    var statusLabel = Label()
    var startButton: Button? = Button()
    var delayedStartButton: Button? = Button()
    var stopButton: Button? = Button()
    var windowSelectionList: WindowSelectionList? = WindowSelectionList()
    var refreshes = 0
    var persists = 0

    func selectedFilePlayer() -> FilePlayer? { filePlayer }
    func cancelCountdown() {
        cancellations += 1
        countdown.cancel()
        delayedWindowSelection = false
        startImmediatelyAfterPreparation = false
    }
    func readControls() {
        profile.sourceKind = ["window", "display", "file"][max(0, sourceKindControl.selectedSegment)]
    }
    func reloadQualityItems() {}
    func applyModeVisibility() {}
    func updateSRCapability() {}
    func refreshSourceBar() {}
    func persist() { persists += 1 }
    func recordPlanEvent(_ event: String) {}
    func refreshPlanLabel() { refreshes += 1 }
    func updateFPSOverlay() {}
    var isEnhancing: Bool { false }

    func testSourceKindChanged() { sourceKindChanged() }
    func testStopImmediately() { stopImmediately() }
    func testRefreshActions() { refreshActions() }

    // ACTUAL_SOURCE_KIND_CHANGED

    // ACTUAL_STOP_IMMEDIATELY

    // ACTUAL_REFRESH_ACTIONS
}

@main
private struct WorkbenchSourceSwitchTests {
    private static var failures = 0

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        let switched = SourceSwitchHarness()
        switched.profile.sourceKind = "window"
        switched.capture.running = true
        switched.pendingApply = 42
        switched.sourceKindControl.selectedSegment = 2
        switched.testSourceKindChanged()
        expect(switched.profile.sourceKind == "file", "Source switch must select file mode")
        expect(switched.capture.stops == 1 && !switched.capture.running,
               "Switching to file must stop live capture; stops=\(switched.capture.stops)")
        expect(switched.processor.stops == 1, "Switching to file must stop the live processor")
        expect(switched.pendingApply == nil && switched.liveApply.cancellations == 1,
               "Switching to file must cancel a pending live plan")

        let stopped = SourceSwitchHarness()
        stopped.profile.sourceKind = "file"
        stopped.capture.running = true
        stopped.pendingApply = 42
        stopped.testStopImmediately()
        expect(stopped.capture.stops == 1 && !stopped.capture.running,
               "Stop in file mode must retire unexpected live capture; stops=\(stopped.capture.stops)")
        expect(stopped.processor.stops == 1, "Stop in file mode must stop the live processor")
        expect(stopped.pendingApply == nil, "Stop in file mode must cancel a pending live plan")

        let visible = SourceSwitchHarness()
        visible.profile.sourceKind = "file"
        visible.capture.running = true
        visible.testRefreshActions()
        expect(visible.stopButton?.isHidden == false, "A running capture must keep Stop visible in file mode")
        expect(visible.stopButton?.title == "Stop Capture", "A running capture must offer Stop Capture in file mode")

        if failures > 0 {
            print("Workbench source-switch lifecycle failed: \(failures) assertions")
            exit(1)
        }
        print("Workbench source-switch lifecycle passed")
    }
}
