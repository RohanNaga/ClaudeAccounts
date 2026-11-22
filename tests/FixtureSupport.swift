// What tests/PromptTest.swift and tests/ResumeTest.swift share: reading the fixture's output as
// it arrives, and polling for a condition the fixture is about to make true.

import Foundation

/// Check `condition` every 100 ms until it holds or `timeout` passes.
func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(100_000)
    }
    return condition()
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
        _ = poll(timeout: timeout) {
            found = all(prefix: prefix).first
            return found != nil
        }
        return found
    }

    /// The rest of every line so far that starts with `prefix`, in order.
    func all(prefix: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
