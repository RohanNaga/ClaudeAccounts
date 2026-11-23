// Claude's quit prompt, read and answered through Accessibility. Kept apart from the app so the
// fixture test in tests/PromptTest.swift drives the same code against a real native alert.

import ApplicationServices
import Foundation

/// Claude's quit prompt is a native alert (a sheet on its window, or a window of its own), so
/// Accessibility can read and press its buttons. Only an alert or sheet with a Quit anyway
/// button counts, never the chat window's web content or another alert Claude has open, so no
/// other button can be pressed by mistake.
enum QuitPrompt {
    static let quitAnyway = ClaudeUI.quitAnyway
    /// How long a new window of Claude's may go without showing a Quit anyway button before the
    /// switch stops trying to answer it and leaves the answer to a person.
    static let findTimeout: TimeInterval = 20

    /// Asked without the system prompt, so an unattended run never opens a dialog itself.
    static var trusted: Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }

    /// Ask macOS to list this app under Accessibility, from a click by the person at the Mac.
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Claude's quit prompt is open. False without Accessibility access.
    static func isOpen(in owners: [pid_t]) -> Bool {
        trusted && owners.contains { !prompts(of: application($0)).isEmpty }
    }

    /// Press the button titled `title` on Claude's quit prompt; true when the press was sent.
    /// A press whose handler keeps the app busy, or ends it, reports cannotComplete although it
    /// landed, so the caller confirms by watching the prompt close or Claude go.
    static func press(_ title: String, in owners: [pid_t]) -> Bool {
        for pid in owners {
            for prompt in prompts(of: application(pid)) {
                if let button = button(title, in: prompt, depth: 0) {
                    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                    return result == .success || result == .cannotComplete
                }
            }
        }
        return false
    }

    /// The alerts and sheets that are Claude's quit prompt: those with a Quit anyway button.
    private static func prompts(of app: AXUIElement) -> [AXUIElement] {
        alerts(of: app).filter { button(quitAnyway, in: $0, depth: 0) != nil }
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        return app
    }

    /// Alert windows (subrole AXDialog) and sheets attached to any window.
    private static func alerts(of app: AXUIElement) -> [AXUIElement] {
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.flatMap { window -> [AXUIElement] in
            if attribute(window, kAXSubroleAttribute) as? String == kAXDialogSubrole { return [window] }
            let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.filter { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
        }
    }

    private static func button(_ title: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
           attribute(element, kAXTitleAttribute) as? String == title { return element }
        guard depth < 3 else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = button(title, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
