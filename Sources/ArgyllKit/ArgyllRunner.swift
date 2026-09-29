import Foundation

public enum ArgyllPrompt: Equatable, Sendable {
    /// The instrument wants to self-calibrate on its white reference tile.
    case placeOnWhiteTile
    /// Move the instrument onto the patch window.
    case placeOnDisplay
    /// Any other "hit any key" prompt, with the text Argyll printed.
    case other(String)
}

public enum ArgyllEvent: Sendable {
    case line(String)
    case progress(done: Int, total: Int)
    case prompt(ArgyllPrompt)
    case error(String)
    case exited(code: Int32)
}

/// Turns Argyll's terminal output into events.
///
/// Argyll blocks on a keypress right after printing a line that ends in ":" with no
/// newline. The words that say what to do are usually on the lines before it, e.g.
///
///     Place the instrument on its reflective white reference S/N 1062057,
///      and then hit any key to continue,
///      or hit Esc or Q to abort:
///
/// so prompts are classified from the last few complete lines plus the unterminated
/// tail, and only when that tail looks like a prompt terminator.
struct ArgyllOutputParser {
    private var tail = ""
    private var pending = Data()
    /// Recent non-empty complete lines, for multi-line prompts.
    private var context: [String] = []
    private static let contextSize = 4

    private static let progress  = try! Regex("[Pp]atch (\\d+) of (\\d+)")
    private static let error     = try! Regex("Error - (.*)$")
    private static let tile      = try! Regex("(white|calibration) (reference|tile)").ignoresCase()
    private static let display   = try! Regex("place (the )?instrument on (the )?(test window|display|screen|spot)").ignoresCase()
    private static let keyPhrase = try! Regex("hit (any|a|esc)|any other key|press (any|a) key").ignoresCase()
    private static let promptEnd = try! Regex(":\\s*$")

    mutating func feed(_ chunk: Data) -> [ArgyllEvent] {
        pending.append(chunk)
        // A chunk can end mid-UTF-8-sequence; keep the bytes until they decode.
        guard let text = String(data: pending, encoding: .utf8) else { return [] }
        pending.removeAll(keepingCapacity: true)

        var events: [ArgyllEvent] = []
        var buffer = (tail + text).replacingOccurrences(of: "\r\n", with: "\n")
        tail = ""
        while let r = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
            let line = String(buffer[..<r.lowerBound])
            buffer = String(buffer[r.upperBound...])
            events.append(contentsOf: classify(line))
            remember(line)
        }
        if buffer.contains(Self.promptEnd), let prompt = promptIn(context + [buffer]) {
            events.append(.line(buffer))
            events.append(.prompt(prompt))
            context.removeAll()
        } else {
            tail = buffer
        }
        return events
    }

    mutating func flush() -> [ArgyllEvent] {
        defer { tail = "" }
        return tail.isEmpty ? [] : classify(tail)
    }

    private mutating func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        context.append(trimmed)
        if context.count > Self.contextSize { context.removeFirst() }
    }

    private func classify(_ line: String) -> [ArgyllEvent] {
        var events: [ArgyllEvent] = [.line(line)]
        if let m = line.firstMatch(of: Self.progress),
           let done = Int(m[1].substring ?? ""),
           let total = Int(m[2].substring ?? "") {
            events.append(.progress(done: done, total: total))
        }
        if let m = line.firstMatch(of: Self.error) {
            events.append(.error(String(m[1].substring ?? "")))
        }
        return events
    }

    private func promptIn(_ lines: [String]) -> ArgyllPrompt? {
        let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        guard text.contains(Self.keyPhrase) else { return nil }
        if text.contains(Self.tile) { return .placeOnWhiteTile }
        if text.contains(Self.display) { return .placeOnDisplay }
        return .other(text)
    }
}

/// One Argyll tool invocation. Consume `events`; call `answerPrompt()` once the
/// user has done what a `.prompt` asked for.
public final class ArgyllRunner {
    public let tool: String
    public let arguments: [String]
    public let events: AsyncStream<ArgyllEvent>

    private let process: PTYProcess

    public init(tool: String, arguments: [String], workingDirectory: String? = nil) throws {
        self.tool = tool
        self.arguments = arguments
        let executable = try Argyll.path(for: tool)
        let process = try PTYProcess(executable: executable,
                                     arguments: arguments,
                                     workingDirectory: workingDirectory)
        self.process = process

        var continuation: AsyncStream<ArgyllEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        let cont = continuation!
        Task.detached {
            var parser = ArgyllOutputParser()
            for await chunk in process.output {
                for event in parser.feed(chunk) { cont.yield(event) }
            }
            for event in parser.flush() { cont.yield(event) }
            let code = await process.waitUntilExit()
            cont.yield(.exited(code: code))
            cont.finish()
        }
    }

    public func answerPrompt() { process.pressAnyKey() }
    public func abort() { process.sendEscape() }
    public func kill() { process.terminate() }
}

public enum Argyll {
    public enum Failure: Error { case toolNotFound(String) }

    /// The app bundle's own copy first (Contents/Helpers), then Homebrew (Apple silicon,
    /// Intel) and MacPorts. Prepend a user-chosen directory if you expose one.
    public static var searchPaths: [String] = [
        Bundle.main.bundlePath + "/Contents/Helpers",
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
    ]

    /// Where the tools actually come from, for an About box or a diagnostics line.
    public static var location: String? { try? path(for: "dispread") }

    public static func path(for tool: String) throws -> String {
        for dir in searchPaths {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw Failure.toolNotFound(tool)
    }

    public struct Display: Sendable {
        public let index: Int
        public let name: String
        public init(index: Int, name: String) { self.index = index; self.name = name }
    }
    public struct Instrument: Sendable {
        public let port: Int
        public let name: String
        public init(port: Int, name: String) { self.port = port; self.name = name }
    }

    /// The "-d n" list from `dispwin -?`. Index 1 is what Argyll calls the primary display.
    public static func displays() async throws -> [Display] {
        try await numberedList(tool: "dispwin", header: "-d n").map { Display(index: $0.0, name: $0.1) }
    }

    /// The "-c listno" list from `spotread -?`: every instrument Argyll can see over USB right now.
    public static func instruments() async throws -> [Instrument] {
        try await numberedList(tool: "spotread", header: "-c listno").map { Instrument(port: $0.0, name: $0.1) }
    }

    private static func numberedList(tool: String, header: String) async throws -> [(Int, String)] {
        let runner = try ArgyllRunner(tool: tool, arguments: ["-?"])
        let entry = try! Regex("^\\s*(\\d+)\\s*=\\s*'(.*)'")
        var inSection = false
        var items: [(Int, String)] = []
        for await event in runner.events {
            guard case .line(let line) = event else { continue }
            if line.contains(header) { inSection = true; continue }
            guard inSection else { continue }
            if let m = line.firstMatch(of: entry), let n = Int(m[1].substring ?? "") {
                items.append((n, String(m[2].substring ?? "")))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                inSection = false
            }
        }
        return items
    }
}
