import Foundation

/// What ccxxmake needs to build a colorimeter correction matrix for one display.
public struct CorrectionOptions: Sendable {
    public var displayIndex: Int
    public var colorimeterPort: Int
    public var spectrometerPort: Int
    /// ccxxmake -t code: u unknown, e white LED, r PFS phosphor, s PFS phosphor IPS, h RG phosphor, b RGB LED, o OLED…
    public var displayTechnology: String = "u"
    public var displayName: String
    public var descriptor: String
    public var outputURL: URL

    public init(displayIndex: Int, colorimeterPort: Int, spectrometerPort: Int, displayName: String, descriptor: String, outputURL: URL) {
        self.displayIndex = displayIndex
        self.colorimeterPort = colorimeterPort
        self.spectrometerPort = spectrometerPort
        self.displayName = displayName
        self.descriptor = descriptor
        self.outputURL = outputURL
    }
}

/// Drives ccxxmake: measures a small patch set with the colorimeter, then with the
/// spectrophotometer, computes the matrix and saves it. ccxxmake is menu-driven; the
/// session answers the menus itself and forwards only the physical steps as prompts.
public actor CorrectionSession {
    public enum Step: String, Sendable { case colorimeter, spectrometer, computing }

    public enum Event: Sendable {
        case line(String)
        case step(Step)
        case progress(done: Int, total: Int)
        case prompt(ArgyllPrompt)
        case exited(code: Int32)
    }

    public struct Result: Sendable {
        public let url: URL
        public let fitAverage: Double?
        public let fitMax: Double?
    }

    public enum Failure: Error {
        case failed(code: Int32, lastError: String?)
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let options: CorrectionOptions
    private var runner: ArgyllRunner?
    /// Answers to the menus, in order: select instrument → colorimeter port, measure,
    /// select instrument → spectrometer port, measure, compute, exit.
    private var keys: [String]
    private var fitAverage: Double?
    private var fitMax: Double?
    private var written = false

    private static let fit = try! Regex("Fit error is avg ([0-9.]+), max ([0-9.]+)")

    public init(options: CorrectionOptions) {
        self.options = options
        keys = ["1", "\(options.colorimeterPort)", "2", "1", "\(options.spectrometerPort)", "2", "3", "4"]
        var continuation: AsyncStream<Event>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func answerPrompt() { runner?.answerPrompt() }
    public func abort() { runner?.abort() }

    public func run() async throws -> Result {
        defer { continuation.finish() }
        let directory = options.outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: options.outputURL)

        // -yn: the matrix must be made on the colorimeter's base calibration (Argyll refuses others).
        let args = ["-v", "-t\(options.displayTechnology)", "-d\(options.displayIndex)", "-yn",
                    "-I", options.displayName, "-E", options.descriptor, options.outputURL.lastPathComponent]
        let runner = try ArgyllRunner(tool: "ccxxmake", arguments: args, workingDirectory: directory.path)
        self.runner = runner
        continuation.yield(.step(.colorimeter))

        var lastError: String?
        var code: Int32 = -1
        for await event in runner.events {
            switch event {
            case .line(let line):
                continuation.yield(.line(line))
                if let m = line.firstMatch(of: Self.fit) {
                    fitAverage = Double(m[1].substring ?? "")
                    fitMax = Double(m[2].substring ?? "")
                }
                if line.contains("Writing CCMX file") && line.contains("succeeded") { written = true }
                if line.contains("Try selecting it again") { lastError = line; runner.kill() }
            case .progress(let done, let total):
                continuation.yield(.progress(done: done, total: total))
            case .prompt(let prompt):
                if case .other(let text) = prompt, text.contains("Press 1 .. ") || text.contains("Select device") {
                    guard !keys.isEmpty else { break }
                    let key = keys.removeFirst()
                    runner.send(key)
                    switch keys.count {                // what the key we just sent leads to
                    case 3: continuation.yield(.step(.spectrometer))   // spectrometer port selected
                    case 1: continuation.yield(.step(.computing))      // "3" sent
                    default: break
                    }
                } else {
                    continuation.yield(.prompt(prompt))
                }
            case .error(let message):
                lastError = message
            case .exited(let exitCode):
                code = exitCode
                continuation.yield(.exited(code: exitCode))
            }
        }
        guard code == 0, written else { throw Failure.failed(code: code, lastError: lastError) }
        return Result(url: options.outputURL, fitAverage: fitAverage, fitMax: fitMax)
    }
}
