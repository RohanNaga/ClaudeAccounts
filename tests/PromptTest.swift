// Drives app/QuitPrompt.swift against tests/PromptFixture.swift, a real native alert with
// Claude's buttons, as a sheet and as a window of its own. It checks that the prompt is seen
// only once it is open, that the ordinary Cancel button in the window is never pressed, and that
// Quit anyway is the button that gets pressed. Needs Accessibility access for the process that
// runs it; ./test.sh skips it, with a note, when that is missing.

import Foundation

@main
struct PromptTest {
    static func main() {
        guard QuitPrompt.trusted else {
            print("Prompt test skipped: this process has no Accessibility access.")
            exit(0)
        }
        let fixture = CommandLine.arguments[1]
        var failures = 0
        for mode in ["--window", "--sheet", "--other"] {
            let result = mode == "--other" ? runOther(fixture) : run(fixture, mode)
            print("\(mode): \(result ?? "ok")")
            if result != nil { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }

    /// One pass; nil when every check held, else what went wrong.
    static func run(_ fixture: String, _ mode: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: fixture)
        proc.arguments = [mode]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        let lines = LineReader(output.fileHandleForReading)
        do { try proc.run() } catch { return "could not start the fixture: \(error)" }
        defer { if proc.isRunning { proc.terminate() } }
        let pid = proc.processIdentifier

        guard lines.wait(for: "ready", timeout: 10) else { return "the fixture window never came up" }
        // The window is up and holds a Cancel button, but no alert is open yet.
        guard poll(timeout: 2, { !QuitPrompt.isOpen(in: [pid]) }) else { return "saw a prompt before one was open" }
        if QuitPrompt.press("Cancel", in: [pid]) { return "pressed a Cancel button outside the prompt" }

        input.fileHandleForWriting.write(Data("show\n".utf8))
        guard poll(timeout: 10, { QuitPrompt.isOpen(in: [pid]) }) else { return "never saw the open prompt" }
        // A sheet is listed before its buttons finish sliding in; the app retries the same way.
        guard poll(timeout: 5, { QuitPrompt.press(QuitPrompt.quitAnyway, in: [pid]) }) else { return "could not press Quit anyway" }
        guard let answer = lines.next(prefix: "pressed: ", timeout: 10) else { return "the fixture never reported an answer" }
        return answer == "Quit anyway" ? nil : "the fixture saw \(answer)"
    }

    /// An unrelated alert of the app is not the quit prompt and none of its buttons is pressed.
    static func runOther(_ fixture: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: fixture)
        proc.arguments = ["--window", "--other"]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        let lines = LineReader(output.fileHandleForReading)
        do { try proc.run() } catch { return "could not start the fixture: \(error)" }
        defer { if proc.isRunning { proc.terminate() } }
        let pid = proc.processIdentifier
        guard lines.wait(for: "ready", timeout: 10) else { return "the fixture window never came up" }
        input.fileHandleForWriting.write(Data("show\n".utf8))
        // Give the alert the same time the quit prompt gets to show, then check it was ignored.
        if poll(timeout: 3, { QuitPrompt.isOpen(in: [pid]) }) { return "took an unrelated alert for the quit prompt" }
        if QuitPrompt.press("Cancel", in: [pid]) { return "pressed Cancel on an unrelated alert" }
        return lines.next(prefix: "pressed: ", timeout: 0.5).map { "the fixture saw \($0)" }
    }

    /// Check `condition` every 100 ms until it holds or `timeout` passes.
    static func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }
}

/// Reads the fixture's output line by line as it arrives.
final class LineReader: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    init(_ handle: FileHandle) {
        var buffer = ""
        handle.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
            buffer += chunk
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer = String(buffer[buffer.index(after: newline)...])
                self?.lock.lock(); self?.lines.append(line); self?.lock.unlock()
            }
        }
    }

    func wait(for line: String, timeout: TimeInterval) -> Bool { next(prefix: line, timeout: timeout) != nil }

    /// The rest of the first line starting with `prefix`, once it arrives.
    func next(prefix: String, timeout: TimeInterval) -> String? {
        var found: String?
        _ = PromptTest.poll(timeout: timeout) {
            lock.lock(); defer { lock.unlock() }
            found = lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            return found != nil
        }
        return found
    }
}
