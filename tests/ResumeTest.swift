// Drives the resume step (ChatResumer in app/ChatComposer.swift) against tests/PromptFixture.swift
// --chats: a stand-in for Claude's chat window plus a decoy window. It checks that each stopped
// chat is opened and found by its session id, gets "resume" in its own message box and one press
// of its own send control, and that the next chat waits for that turn to start. A running chat,
// a chat with an unsent draft and the decoy get nothing; Retry, Rewind and Stop are never pressed;
// a chat is never sent to twice; and the fixture never gets keyboard focus. Needs Accessibility
// access for the process that runs it; ./test.sh skips it, with a note, when that is missing.

import ApplicationServices
import Foundation

@main
struct ResumeTest {
    static var failures = 0

    static func check(_ condition: Bool, _ what: String) {
        print("\(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func main() async {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) else {
            print("Resume test skipped: this process has no Accessibility access.")
            exit(0)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        proc.arguments = ["--chats"]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        let lines = LineReader(output.fileHandleForReading)
        do { try proc.run() } catch { print("could not start the fixture: \(error)"); exit(1) }
        defer { if proc.isRunning { proc.terminate() } }
        let pid = proc.processIdentifier
        func say(_ line: String) { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }
        guard lines.wait(for: "ready", timeout: 10) else { print("the fixture never came up"); exit(1) }

        // Before anything is opened, the target isn't on screen; the decoy is, idle and empty.
        check(ChatComposer.screen(session: "local_target", in: [pid]) == nil, "a chat no window shows is not found")
        check(ChatComposer.screen(session: "local_decoy", in: [pid]) == ChatScreen(busy: false, composer: true, draft: false),
              "the decoy window's chat is found by its id")
        check(ChatComposer.send("resume", session: "local_target", in: [pid]) == .refused("Claude didn't show it"),
              "sending to a chat no window shows is refused")

        func chat(_ id: String, _ order: Double) -> MovedChat { MovedChat(id: id, title: id, interrupted: false, lastActivity: order) }
        let target = chat("local_target", 4), busy = chat("local_busy", 3), draft = chat("local_draft", 2), second = chat("local_second", 1)
        let resumer = ChatResumer(open: { id in say("open \(id)") }, pids: { [pid] }, running: { _ in false })

        // The target twice: the step sends to a chat once, whatever list it is handed.
        let reports = await resumer.run([target, busy, draft, target, second])
        check(reports.map(\.chat.id) == ["local_target", "local_busy", "local_draft", "local_second"], "one report per chat, in order")
        check(reports.map(\.result) == [.sent, .running, .notResumed("it has an unsent draft"), .sent],
              "sent, already running, draft kept, sent: got \(reports.map(\.result))")

        let sent = lines.all(prefix: "sent: ")
        check(sent == ["local_target resume", "local_second resume"], "exactly one \"resume\" to each idle stopped chat, target first: got \(sent)")
        check(lines.all(prefix: "pressed: ").isEmpty, "no other button was pressed (Retry, Rewind, Stop): got \(lines.all(prefix: "pressed: "))")

        // A second pass finds both chats running and sends nothing more.
        let again = await resumer.run([target, second])
        check(again.map(\.result) == [.running, .running], "a chat the step already sent to is running and is not sent to again")
        check(lines.all(prefix: "sent: ").count == 2, "still exactly two messages sent")

        say("state")
        guard lines.wait(for: "focus: ", timeout: 10) else { print("the fixture never reported its state"); exit(1) }
        let boxes = lines.all(prefix: "box: ")
        check(boxes.contains("local_draft [a note I haven't sent]"), "the unsent draft is untouched")
        check(boxes.contains("local_decoy []"), "the decoy's message box is untouched")
        check(lines.next(prefix: "focus: ", timeout: 0) == "key=false active=false", "the fixture never had keyboard focus")

        print(failures == 0 ? "Resume test: ok" : "Resume test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
