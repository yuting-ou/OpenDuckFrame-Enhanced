import AppKit
import ScreenCaptureKit

// The workbench supplies its own localization helper in the app target.
enum EnhancementText {
    static var chinese = true
    static func t(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
}

@main
struct WindowPermissionPromptTests {
    @MainActor static func textFields(in view: NSView) -> [String] {
        let ownText = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return ownText + view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        var systemRequests = 0
        var refresh: NSButton?
        let permission = ScreenCapturePermission(preflight: { false }, request: {
            systemRequests += 1
            // A system dialog may re-enter the main run loop.
            refresh?.performClick(nil)
            return false
        })
        let list = WindowSelectionList(permission: permission) { _ in
            preconditionFailure("Refreshing must not choose a window")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = list

        // Background refresh does not request permission. A user click asks
        // once, but must not stack an app sheet over the pending system dialog.
        list.reloadWindows()
        precondition(systemRequests == 0)
        let settings = list.subviews.compactMap { $0 as? NSButton }.first { $0.title == "打开系统设置" }
        precondition(settings?.isHidden == true, "Initial loading must not open permission recovery")
        refresh = list.subviews.compactMap { $0 as? NSButton }.first { $0.title == "刷新列表" }
        guard let refresh else { preconditionFailure("Refresh button is missing") }
        refresh.performClick(nil)
        precondition(systemRequests == 1, "The user gesture must request recording access")
        precondition(window.attachedSheet == nil, "The system prompt must not be covered by an app sheet")
        precondition(settings?.isHidden == false, "Denied access needs an explicit Settings action")
        let explanation = textFields(in: list).joined(separator: " ")
        precondition(explanation.contains("开关已打开") && explanation.contains("移除旧的 OpenDuckFrame") &&
                     explanation.contains("添加当前应用") && explanation.contains(Bundle.main.bundleURL.path),
                     "The explanation must recover a stale permission entry for the current app")
        for _ in 0..<20 { refresh.performClick(nil) }
        list.reloadWindows()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        precondition(systemRequests == 1 && window.attachedSheet == nil, "Repeated refreshes and focus changes must not stack prompts")
        precondition(textFields(in: list).joined(separator: " ") == explanation, "Background reload must preserve recovery instructions")
        window.contentView?.layoutSubtreeIfNeeded()
        guard let footer = list.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue.contains("开关已打开") }) else {
            preconditionFailure("The inline explanation is missing")
        }
        precondition(footer.maximumNumberOfLines == 0 && footer.frame.height > 25, "Recovery instructions must wrap instead of being truncated")
        precondition(settings!.frame.minX > list.subviews.compactMap({ $0 as? NSTextField }).first!.frame.maxX,
                     "The Settings action must not overlap the heading")

        // When the system grants the request, the same button proceeds to
        // refresh the list without an app-owned denial sheet.
        var granted = false
        var grantRequests = 0
        let grant = ScreenCapturePermission(preflight: { granted }, request: {
            grantRequests += 1
            granted = true
            return true
        })
        let grantedList = WindowSelectionList(permission: grant) { _ in
            preconditionFailure("Refreshing must not select a window")
        }
        let grantedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        grantedWindow.contentView = grantedList
        guard let grantedRefresh = grantedList.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "刷新列表" }) else {
            preconditionFailure("Refresh button is missing")
        }
        grantedRefresh.performClick(nil)
        let grantedFooter = grantedList.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        precondition(grantRequests == 1 && grantedWindow.attachedSheet == nil)
        precondition(grantedFooter.contains("正在获取窗口…"), "A granted request must refresh the list")
        precondition(grantedList.subviews.compactMap { $0 as? NSButton }.first { $0.title == "打开系统设置" }?.isHidden == true)

        // Granting permission directly in System Settings must also refresh on
        // return, even when the app did not open System Settings itself.
        var externallyGranted = false
        var externalRequests = 0
        let externalPermission = ScreenCapturePermission(preflight: { externallyGranted }, request: {
            externalRequests += 1
            return false
        })
        let externalList = WindowSelectionList(permission: externalPermission) { _ in
            preconditionFailure("Refreshing must not select a window")
        }
        externalList.reloadWindows()
        externalList.refreshFromUser()
        precondition(externalRequests == 1)
        externallyGranted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let externalFooter = externalList.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        precondition(externalRequests == 1, "Returning to the app must not request permission again")
        precondition(externalFooter.contains("正在获取窗口…"), "A newly granted permission must refresh the list")
        precondition(externalList.subviews.compactMap { $0 as? NSButton }.first { $0.title == "打开系统设置" }?.isHidden == true,
                     "A newly granted permission must hide recovery controls")

        // The same recovery must fit the minimum workbench width in English.
        EnhancementText.chinese = false
        let englishList = WindowSelectionList(permission: permission) { _ in
            preconditionFailure("Refreshing must not select a window")
        }
        let englishWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 218),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        englishWindow.contentView = englishList
        englishList.appearance = NSAppearance(named: .darkAqua)
        englishList.refreshFromUser()
        englishList.layoutSubtreeIfNeeded()
        let englishButtons = englishList.subviews.compactMap { $0 as? NSButton }
        let englishSettings = englishButtons.first { $0.title == "Open System Settings" }!
        let englishRefresh = englishButtons.first { $0.title == "Refresh list" }!
        let englishFields = englishList.subviews.compactMap { $0 as? NSTextField }
        let englishHeading = englishFields.first { $0.stringValue == "Target window" }!
        let englishFooter = englishFields.first { $0.stringValue.contains("Screen Recording access is needed") }!
        precondition(systemRequests == 1 && englishWindow.attachedSheet == nil)
        precondition(!englishSettings.isHidden && englishHeading.frame.maxX < englishSettings.frame.minX &&
                     englishSettings.frame.maxX < englishRefresh.frame.minX, "English recovery actions must fit the minimum width")
        precondition(englishFooter.frame.height > 25 && englishFooter.frame.maxY < englishRefresh.frame.minY,
                     "English recovery must wrap within the list")
        print("Window permission prompt tests passed")
    }
}
