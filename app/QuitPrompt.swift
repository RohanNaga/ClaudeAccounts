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

    /// Asked without the system prompt, so an unattended run never opens a dialog itself.
    static var trusted: Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }

    /// Ask macOS to list this app under Accessibility, from a click by the person at the Mac.
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Claude's quit prompt is open. False without Accessibility access.
    static func isOpen(in owners: [pid_t]) -> Bool { survey(in: owners).quitAnyway }

    /// What Accessibility shows of Claude's windows now: each window's role and subrole, and the
    /// button titles on each alert or sheet. Empty without Accessibility access, or when Claude
    /// doesn't answer within the messaging timeout; the caller looks again.
    static func survey(in owners: [pid_t]) -> QuitSurvey {
        guard trusted else { return QuitSurvey() }
        var seen = QuitSurvey()
        for pid in owners {
            for window in attribute(application(pid), kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                let subrole = attribute(window, kAXSubroleAttribute) as? String
                seen.windows.append("\(attribute(window, kAXRoleAttribute) as? String ?? "?")/\(subrole ?? "?")")
                if subrole == kAXDialogSubrole { seen.prompts.append(buttons(in: window, depth: 0)) }
                for sheet in (attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []) where attribute(sheet, kAXRoleAttribute) as? String == kAXSheetRole {
                    seen.windows.append(kAXSheetRole)
                    seen.prompts.append(buttons(in: sheet, depth: 0))
                }
            }
        }
        return seen
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

    /// The titles of the buttons within three levels of `element`.
    private static func buttons(in element: AXUIElement, depth: Int) -> [String] {
        var titles: [String] = []
        if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole, let title = attribute(element, kAXTitleAttribute) as? String {
            titles.append(title)
        }
        guard depth < 3 else { return titles }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { titles += buttons(in: child, depth: depth + 1) }
        return titles
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
