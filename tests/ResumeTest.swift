// Drives the resume step (ChatResumer in app/ChatComposer.swift) against tests/PromptFixture.swift
// --chats: a stand-in for Claude's chat window, laid out as Claude's Code tab reads through
// Accessibility, plus a decoy window. Each stopped chat is opened and found by its session id;
// "resume" goes into its own message box although Send shows only once the box holds text, and
// its Send is pressed once; the next chat waits for that turn to start. That holds with a side
// panel and an artifact's own Prompt box open, with the next-step box's suggested replies, with a
// box named only by its placeholder, with a page that loads slowly, and with one that loads only
// after the first pass gave up, which the retry schedule picks up. A running chat, a chat with an
// unsent draft and the decoy get nothing; Retry, Rewind, Stop and the suggested replies are never
// pressed; a chat is never sent to twice, even across retries; retries end after ResumeRule's
// 30 minutes; and the fixture never gets keyboard focus. The retry schedule runs on a clock the
// test advances, so nothing here waits it out. Needs Accessibility access for the process that
// runs it; ./test.sh skips it, with a note, when that is missing.

import ApplicationServices
import Foundation

/// The resume step's clock, advanced by its own sleeps; `onSleep` lets the fixture's pages load
/// at a set time on it.
final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
    var onSleep: (Date) -> Void = { _ in }
    var resumeClock: ResumeClock {
        ResumeClock(now: { self.now }, sleep: { seconds in
            self.now = self.now.addingTimeInterval(seconds)
            self.onSleep(self.now)
        })
    }
}

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
        guard lines.wait(for: "ready", timeout: 10) else { print("the fixture never came up"); exit(1) }

        /// Send a command and return once the fixture answers it.
        func tell(_ command: String, answer: String) {
            let before = lines.all(prefix: answer).count
            input.fileHandleForWriting.write(Data((command + "\n").utf8))
            if !poll(timeout: 10, { lines.all(prefix: answer).count > before }) { print("the fixture never answered \(command)"); exit(1) }
        }
        let clock = TestClock()
        var firstOpened: [String: Date] = [:]
        var traced: [String] = []
        func resumer() -> ChatResumer {
            ChatResumer(open: { id in
                            if firstOpened[id] == nil { firstOpened[id] = clock.now }
                            tell("open \(id)", answer: "shown: \(id)")
                        },
                        pids: { [pid] }, resumedByClaude: { _ in false }, trace: { traced.append($0) },
                        idleSeconds: { 3600 }, clock: clock.resumeClock)
        }

        // Before anything is opened, the target isn't on screen; the decoy is, idle and empty,
        // and counts as ready though Claude shows no Send beside an empty box.
        check(ChatComposer.screen(session: "local_target", in: [pid]) == nil, "a chat no window shows is not found")
        check(ChatComposer.screen(session: "local_decoy", in: [pid]) == ChatScreen(busy: false, composer: true, draft: false),
              "the decoy window's chat is found by its id, its message box ready without a Send button")
        check(ChatComposer.send("resume", session: "local_target", in: [pid]) == .refused("Claude didn't show it"),
              "sending to a chat no window shows is refused")

        // Slow loads: one shows its message box 30 s after it was opened, past the old 20 s
        // limit; the other only after the first pass gave up on it, so a retry gets it.
        var loads: [String: TimeInterval] = ["local_slow": 30, "local_late": ResumeRule.readyWait + 30]
        clock.onSleep = { now in
            for (id, after) in loads {
                guard let at = firstOpened[id], now.timeIntervalSince(at) >= after else { continue }
                loads[id] = nil
                tell("load \(id)", answer: "loaded: \(id)")
            }
        }
        func chat(_ id: String, _ order: Double) -> MovedChat { MovedChat(id: id, title: id, interrupted: false, lastActivity: order) }
        let order = ["local_target", "local_busy", "local_draft", "local_target", "local_panel", "local_nextstep",
                     "local_placeholder", "local_slow", "local_late", "local_second"]
        let wanted = order.enumerated().map { chat($0.element, Double(order.count - $0.offset)) }

        // The target twice: the step sends to a chat once, whatever list it is handed.
        let reports = await resumer().run(wanted)
        let expected: [String: ResumeRule.Result] = [
            "local_target": .sent, "local_busy": .running, "local_draft": .draft, "local_panel": .sent, "local_nextstep": .sent,
            "local_placeholder": .sent, "local_slow": .sent, "local_late": .sent, "local_second": .sent,
        ]
        check(reports.map(\.chat.id) == ["local_target", "local_busy", "local_draft", "local_panel", "local_nextstep",
                                         "local_placeholder", "local_slow", "local_late", "local_second"],
              "one report per chat, in order")
        for report in reports {
            check(report.result == expected[report.chat.id], "\(report.chat.id): \(expected[report.chat.id]!) (got \(report.result))")
        }
        let sent = lines.all(prefix: "sent: ")
        check(sent == ["local_target resume", "local_panel resume", "local_nextstep resume", "local_placeholder resume",
                       "local_slow resume", "local_second resume", "local_late resume"],
              "exactly one \"resume\" to each idle stopped chat, the late one on the second pass: got \(sent)")
        check(lines.all(prefix: "pressed: ").isEmpty,
              "no other control was pressed (Retry, Rewind, Stop, the suggested replies, the artifact's Send): got \(lines.all(prefix: "pressed: "))")
        check(traced.contains("found its message box: \(ComposerRule.FoundBy.name.rawValue)"),
              "the message box is found by its name, past the side panel's address field and the artifact's own Prompt box")
        check(traced.contains("found its message box: \(ComposerRule.FoundBy.multiline.rawValue)"),
              "a message box named only by its placeholder is found as the page's only multi-line text box")
        check(traced.contains("pressed Send message") && traced.contains { $0.hasPrefix("pressed ") && $0 != "pressed Send message" },
              "Send is pressed by its name, and an unnamed Send by being the one control that appeared with the text")
        check(traced.filter { $0.hasPrefix("pass ") }.count == 2 && clock.now.timeIntervalSince1970 >= ResumeRule.retryEvery,
              "the chat that loaded late got its message on the next pass, a minute on the clock after the first")

        // A second run finds them all running and sends nothing more.
        let again = await resumer().run(["local_target", "local_second", "local_late"].map { chat($0, 1) })
        check(again.map(\.result) == [.running, .running, .running], "a chat the step already sent to is running and is not sent to again")
        check(lines.all(prefix: "sent: ").count == 7, "still exactly seven messages sent")

        // A chat that never shows its message box is tried every minute while the schedule lasts,
        // then reported; one whose message went without a reply is never sent a second.
        clock.now = Date(timeIntervalSince1970: 0)
        traced = []
        let last = await resumer().run([chat("local_never", 2), chat("local_mute", 1)])
        check(last.map(\.result) == [.notResumed("its message box wasn't found"), .notResumed(ChatResumer.noReply)],
              "after the schedule both are reported with their reason: got \(last.map(\.result))")
        let passes = traced.filter { $0.hasPrefix("pass ") }.count
        check(passes > 2 && clock.now.timeIntervalSince1970 <= ResumeRule.retryFor + ResumeRule.readyWait + ResumeRule.startWait,
              "it tried again every minute and stopped once the 30 minutes were up: \(passes) passes, \(Int(clock.now.timeIntervalSince1970)) s")
        check(lines.all(prefix: "sent: ").filter { $0.hasPrefix("local_mute") }.count == 1, "the chat that got no reply was sent one message, not one per pass")
        check(lines.all(prefix: "sent: ").filter { $0.hasPrefix("local_never") }.isEmpty, "the chat that never loaded was never typed into")

        // Another switch starts 30 s into a resume: it stops there, types into nothing after that,
        // and doesn't wait out its schedule. The idle decoy would have been sent a message.
        clock.now = Date(timeIntervalSince1970: 0)
        traced = []
        var cut = resumer()
        cut.current = { clock.now.timeIntervalSince1970 < 30 }
        let stopped = await cut.run([chat("local_never", 2), chat("local_decoy", 1)])
        check(stopped.map(\.result) == [.notResumed(ChatResumer.superseded), .notResumed(ChatResumer.superseded)],
              "a resume another switch overtook reports both chats as left for that switch: got \(stopped.map(\.result))")
        check(traced.filter { $0.hasPrefix("pass ") }.count == 1 && clock.now.timeIntervalSince1970 < ResumeRule.retryEvery,
              "it stopped in its first pass instead of trying again for 30 minutes")
        check(firstOpened["local_decoy"] == nil && lines.all(prefix: "sent: ").count == 8,
              "it never opened the next chat, and sent nothing more")

        tell("state", answer: "focus: ")
        let boxes = lines.all(prefix: "box: ")
        check(boxes.contains("local_draft [a note I haven't sent]"), "the unsent draft is untouched")
        check(boxes.contains("local_decoy []"), "the decoy's message box is untouched")
        check(lines.all(prefix: "focus: ").last == "key=false active=false", "the fixture never had keyboard focus")

        print(failures == 0 ? "Resume test: ok" : "Resume test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
