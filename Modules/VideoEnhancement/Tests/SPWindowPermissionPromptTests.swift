import AppKit
import ScreenCaptureKit

// Keep language selection in memory; never change the user's preferences.
@MainActor enum EnhancementText {
    static var chinese = true
    static func t(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
}

@main
@MainActor
struct WindowPermissionPromptTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        let ownView = (view as? T).map { [$0] } ?? []
        return ownView + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    static func button(_ title: String, in list: WindowSelectionList) -> NSButton? {
        descendants(of: NSButton.self, in: list).first { $0.title == title }
    }

    static func texts(in list: WindowSelectionList) -> [String] {
        descendants(of: NSTextField.self, in: list)
            .filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }

    static func host(_ list: WindowSelectionList) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        list.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            list.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        return window
    }

    static func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        window.close()
    }

    static func switchFocus() {
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    static func verifyRecoveryLayout(in list: WindowSelectionList, window: NSWindow,
                                     settingsTitle: String, permissionText: String) {
        guard let settings = button(settingsTitle, in: list) else {
            expect(false, "Denied access needs an explicit \(settingsTitle) button")
            return
        }
        expect(!settings.isHiddenOrHasHiddenAncestor && settings.isEnabled,
               "The recovery button must be visible and enabled")
        expect(settings.target === list && settings.action.map { list.responds(to: $0) } == true,
               "The recovery button must have a settings action; do not invoke it in this test")
        guard let help = descendants(of: NSTextField.self, in: list).first(where: {
            !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains(permissionText)
        }) else {
            expect(false, "Denied access needs an inline permission explanation")
            return
        }
        expect(help.stringValue.contains("OpenDuckFrame"), "Inline help must identify the app to allow")
        expect(help.lineBreakMode == .byWordWrapping && help.maximumNumberOfLines != 1,
               "Permission help must wrap across multiple lines, not truncate")
        let recovery = help.stringValue + " " + (help.toolTip ?? "")
        let recoverySteps = EnhancementText.chinese
            ? ["开关已打开", "移除旧的 OpenDuckFrame", "添加当前应用"]
            : ["already enabled", "remove the old OpenDuckFrame", "add the current app"]
        expect(recoverySteps.allSatisfy { recovery.contains($0) } && recovery.contains(Bundle.main.bundleURL.path),
               "Inline recovery must preserve stale-entry guidance for the current app")
        guard let scroll = descendants(of: NSScrollView.self, in: list).first else {
            preconditionFailure("Window list scroll view is missing")
        }
        guard let heading = descendants(of: NSTextField.self, in: list).first(where: {
            $0.stringValue == (EnhancementText.chinese ? "目标窗口" : "Target window")
        }), let refresh = button(EnhancementText.chinese ? "刷新列表" : "Refresh list", in: list) else {
            preconditionFailure("Window list heading or refresh button is missing")
        }
        for width: CGFloat in [540, 560, 900] {
            window.setContentSize(NSSize(width: width, height: 300))
            window.contentView?.layoutSubtreeIfNeeded()
            let context = "\(EnhancementText.chinese ? "zh" : "en") at window width \(width)"
            let helpRect = list.convert(help.alignmentRect(forFrame: help.bounds), from: help)
            let settingsRect = list.convert(settings.alignmentRect(forFrame: settings.bounds), from: settings)
            let scrollRect = list.convert(scroll.bounds, from: scroll)
            expect(abs(list.bounds.width - (width - 40)) < 1, "The list must follow resizing: \(context)")
            for (name, rect) in [("help", helpRect), ("settings", settingsRect)] {
                expect(rect.width > 0 && rect.height > 0 && list.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                       "Recovery \(name) must fit inside the list: \(context), control=\(rect), list=\(list.bounds)")
            }
            let requiredHeight = help.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: help.bounds.width,
                                                                      height: 1000)).height ?? 0
            expect(requiredHeight <= help.bounds.height + 1, "Permission text must not be clipped: \(context)")
            if width == 540, let font = help.font {
                expect(help.bounds.height > ceil(font.ascender - font.descender + font.leading),
                       "Narrow permission help must render on multiple lines: \(context)")
            }
            let headingRect = list.convert(heading.bounds, from: heading)
            let refreshRect = list.convert(refresh.alignmentRect(forFrame: refresh.bounds), from: refresh)
            expect(!headingRect.intersects(settingsRect) && !refreshRect.intersects(settingsRect),
                   "The settings action must not overlap the heading or refresh button: \(context)")
            expect(settings.frame.width + 1 >= settings.fittingSize.width,
                   "The settings button title must not be clipped: \(context)")
            expect(!helpRect.intersects(settingsRect) && !scrollRect.intersects(helpRect) &&
                   !scrollRect.intersects(settingsRect) && scrollRect.height > 0,
                   "Recovery controls and window rows must not overlap: \(context)")
        }
    }

    static func deniedRefreshAndExternalGrant(chinese: Bool) {
        EnhancementText.chinese = chinese
        let refreshTitle = chinese ? "刷新列表" : "Refresh list"
        let settingsTitle = chinese ? "打开系统设置" : "Open System Settings"
        let permissionText = chinese ? "屏幕录制权限" : "Screen Recording"
        let loadingText = chinese ? "正在获取窗口…" : "Loading windows…"
        var allowed = false
        var systemRequests = 0
        var refresh: NSButton?
        let permission = ScreenCapturePermission(preflight: { allowed }, request: {
            systemRequests += 1
            // Simulate re-entry while the system permission dialog is still open.
            refresh?.performClick(nil)
            switchFocus()
            return false
        })
        let list = WindowSelectionList(permission: permission) { _ in
            preconditionFailure("Refreshing must not choose a window")
        }
        let window = host(list)
        defer { close(window) }
        list.reloadWindows()
        switchFocus()
        expect(systemRequests == 0 && window.attachedSheet == nil,
               "Automatic refresh and focus changes must not request permission or show a sheet")
        expect(button(settingsTitle, in: list)?.isHiddenOrHasHiddenAncestor == true,
               "Automatic refresh must not display recovery controls before a user request")
        guard let refreshButton = button(refreshTitle, in: list) else {
            preconditionFailure("Refresh button is missing")
        }
        refresh = refreshButton
        refreshButton.performClick(nil)
        expect(systemRequests == 1, "The explicit refresh must request recording access once")
        expect(window.attachedSheet == nil, "Denied refresh must not add an app sheet over the system prompt")
        verifyRecoveryLayout(in: list, window: window, settingsTitle: settingsTitle, permissionText: permissionText)
        for _ in 0..<20 {
            refreshButton.performClick(nil)
            switchFocus()
            expect(systemRequests == 1 && window.attachedSheet == nil,
                   "Repeated refresh and focus changes must not stack prompts or repeat the system request")
        }
        let recoveryText = texts(in: list)
        list.reloadWindows()
        expect(texts(in: list) == recoveryText, "Automatic reload must preserve visible recovery instructions")
        expect(texts(in: list).contains { $0.contains(permissionText) && $0.contains("OpenDuckFrame") },
               "Recovery guidance must remain visible after repeated refresh and focus changes")
        allowed = true
        switchFocus()
        expect(systemRequests == 1, "Returning after an external grant must not request permission again")
        expect(texts(in: list).contains(loadingText), "Returning after a grant must refresh the window list")
        expect(window.attachedSheet == nil, "Granting access must leave no permission sheet")
        expect(button(settingsTitle, in: list)?.isHiddenOrHasHiddenAncestor == true,
               "Granting access must hide the settings recovery button")
        expect(!texts(in: list).contains { $0.contains(permissionText) },
               "Granting access must replace permission guidance with normal list status")
    }

    static func grantedRequestRefreshes() {
        EnhancementText.chinese = true
        var granted = false
        var requests = 0
        let permission = ScreenCapturePermission(preflight: { granted }, request: {
            requests += 1
            granted = true
            return true
        })
        let list = WindowSelectionList(permission: permission) { _ in
            preconditionFailure("Refreshing must not select a window")
        }
        let window = host(list)
        defer { close(window) }
        list.reloadWindows()
        guard let refresh = button("刷新列表", in: list) else { preconditionFailure("Refresh button is missing") }
        refresh.performClick(nil)
        expect(requests == 1 && window.attachedSheet == nil, "An immediate grant must not show a denial sheet")
        expect(texts(in: list).contains("正在获取窗口…"), "An immediate grant must refresh the list")
        expect(button("打开系统设置", in: list)?.isHiddenOrHasHiddenAncestor == true,
               "An immediate grant must hide recovery controls")
    }

    static func externalGrantWithoutRequestRefreshes() {
        EnhancementText.chinese = true
        var granted = false
        var requests = 0
        let permission = ScreenCapturePermission(preflight: { granted }, request: {
            requests += 1
            return false
        })
        let list = WindowSelectionList(permission: permission) { _ in
            preconditionFailure("Refreshing must not select a window")
        }
        list.reloadWindows()
        granted = true
        switchFocus()
        expect(requests == 0, "Returning after a grant without a prior user request must not prompt")
        expect(texts(in: list).contains("正在获取窗口…"), "An external grant must refresh even without a prior request")
    }

    static func main() {
        _ = NSApplication.shared
        // Stay synchronous so granted-path capture Tasks never execute real ScreenCaptureKit calls.
        deniedRefreshAndExternalGrant(chinese: true)
        deniedRefreshAndExternalGrant(chinese: false)
        grantedRequestRefreshes()
        externalGrantWithoutRequestRefreshes()
        if failures > 0 {
            print("Window permission prompt tests failed: \(failures) assertions")
            exit(1)
        }
        print("Window permission prompt tests passed (denied/re-entry/20 refreshes/grants; zh/en at 540/560/900)")
    }
}
