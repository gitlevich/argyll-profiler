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
    /// Patch window position and size (-P), same meaning as ProfilingOptions.patchWindow.
    public var patchWindow: ProfilingOptions.PatchWindow? = nil
    /// -N: reuse the spectrophotometer's last white-tile calibration if Argyll still considers it valid.
    public var skipInstrumentCalibrationIfPossible: Bool = false

    /// The ccxxmake argument list this configuration produces (exposed for tests).
    public var arguments: [String] {
        var args = ["-v", "-t\(displayTechnology)", "-d\(displayIndex)", "-yn"]
        if skipInstrumentCalibrationIfPossible { args.append("-N") }
        if let window = patchWindow { args.append(window.argument) }
        args += ["-I", displayName, "-E", descriptor, outputURL.lastPathComponent]
        return args
    }

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
    /// The menu's last option number, once "Press 1 .. N:" has been seen and its options are still printing.
    private var menuLastOption: Int?

    private static let fit = try! Regex("Fit error is avg ([0-9.]+), max ([0-9.]+)")
    private static let menuHeader = try! Regex("Press 1 \\.\\. (\\d+):")
    private static let optionLine = try! Regex("^\\s*(\\d+)\\) ")
    private static let selectDevice = try! Regex("Select device \\d+ - \\d+:")

    /// Argyll discards typed-ahead input just before it reads a key, so a key must arrive only
    /// after the prompt has fully printed. A short delay is the robust way to guarantee that.
    private func sendNextKey(_ runner: ArgyllRunner) async {
        guard !keys.isEmpty else { return }
        let key = keys.removeFirst()
        try? await Task.sleep(nanoseconds: 400_000_000)
        runner.send(key)
        switch keys.count {                // what the key just sent leads to
        case 3: continuation.yield(.step(.spectrometer))   // spectrometer port selected
        case 1: continuation.yield(.step(.computing))      // "3" sent
        default: break
        }
    }

    public init(options: CorrectionOptions) {
        self.options = options
        keys = ["1", "\(options.colorimeterPort)", "2", "1", "\(options.spectrometerPort)", "2", "3", "4"]
        var continuation: AsyncStream<Event>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func answerPrompt() { runner?.answerPrompt() }
    /// ccxxmake's menu ignores Escape, so cancelling terminates the tool outright.
    public func abort() { runner?.kill() }

    public func run() async throws -> Result {
        defer { continuation.finish() }
        let directory = options.outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: options.outputURL)

        // -yn: the matrix must be made on the colorimeter's base calibration (Argyll refuses others).
        let runner = try ArgyllRunner(tool: "ccxxmake", arguments: options.arguments, workingDirectory: directory.path)
        self.runner = runner
        continuation.yield(.step(.colorimeter))

        var lastError: String?
        var code: Int32 = -1
        for await event in runner.events {
            switch event {
            case .line(let line):
                continuation.yield(.line(line))
                // The menu is answered only after its last option line has been printed.
                if let last = menuLastOption, let m = line.firstMatch(of: Self.optionLine),
                   Int(m[1].substring ?? "") == last {
                    menuLastOption = nil
                    await sendNextKey(runner)
                }
                if let m = line.firstMatch(of: Self.fit) {
                    fitAverage = Double(m[1].substring ?? "")
                    fitMax = Double(m[2].substring ?? "")
                }
                if line.contains("Writing CCMX file") && line.contains("succeeded") { written = true }
                if line.contains("Try selecting it again") { lastError = line; runner.kill() }
            case .progress(let done, let total):
                continuation.yield(.progress(done: done, total: total))
            case .prompt(let prompt):
                if case .other(let text) = prompt, let m = text.firstMatch(of: Self.menuHeader) {
                    menuLastOption = Int(m[1].substring ?? "")          // menu: answer once "N) …" has printed
                } else if case .other(let text) = prompt, text.contains(Self.selectDevice) {
                    await sendNextKey(runner)                            // device list: answer now
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
