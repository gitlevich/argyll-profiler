import Foundation

public struct ProfilingOptions: Sendable {
    /// From `Argyll.displays()`.
    public var displayIndex: Int
    /// From `Argyll.instruments()`.
    public var instrumentPort: Int = 1
    /// Base name for the .ti1/.ti3/.cal/.icc files and the profile description.
    public var profileName: String
    /// targen -f. The i1Pro 2 is noisy near black, so 400+ patches beats 175 on a display.
    public var patchCount: Int = 175
    /// l / m / h for dispcal and colprof.
    public var quality: Character = "m"
    /// -H, the i1Pro 2 high-resolution spectral mode.
    public var hiRes: Bool = true
    /// nil profiles the display as it is. That is the right choice for a Studio Display
    /// sitting in an Apple reference preset: no gamma-table curves, just a description
    /// of what the display does. Set it to run dispcal first and embed vcgt curves.
    public var calibration: Calibration? = nil
    /// If set, dispread serves patches at http://localhost:PORT instead of drawing its
    /// own window. Show that URL in a borderless full-screen WKWebView on the target
    /// NSScreen and you own placement, warm-up and the "cover the sensor" overlay.
    public var patchServerPort: Int? = nil
    /// false leaves the finished .icc in the working directory without installing or
    /// assigning it (dispwin -I). Useful for test runs and for validation-only passes.
    public var installProfile: Bool = true

    public struct Calibration: Sendable {
        /// nil keeps the native white.
        public var whitePointKelvin: Int? = 6500
        public var gamma: Double = 2.2
        public init(whitePointKelvin: Int? = 6500, gamma: Double = 2.2) {
            self.whitePointKelvin = whitePointKelvin
            self.gamma = gamma
        }
    }

    public init(displayIndex: Int, instrumentPort: Int = 1, profileName: String) {
        self.displayIndex = displayIndex
        self.instrumentPort = instrumentPort
        self.profileName = profileName
    }
}

/// Runs the whole Argyll pipeline in a working directory and installs the result.
///
/// Consume `events` for UI. On `.prompt`, tell the user what to do, then call
/// `answerPrompt()`; the session forwards the keypress to whichever tool is waiting.
public actor ProfilingSession {
    public enum Stage: String, CaseIterable, Sendable {
        case targen, dispcal, dispread, colprof, dispwin
    }

    public enum Failure: Error {
        case stageFailed(Stage, code: Int32, lastError: String?)
    }

    public nonisolated let events: AsyncStream<(Stage, ArgyllEvent)>
    public let directory: URL

    private let options: ProfilingOptions
    private let continuation: AsyncStream<(Stage, ArgyllEvent)>.Continuation
    private var current: ArgyllRunner?

    public init(options: ProfilingOptions, directory: URL) {
        self.options = options
        self.directory = directory
        var continuation: AsyncStream<(Stage, ArgyllEvent)>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func answerPrompt() { current?.answerPrompt() }
    public func abort() { current?.abort() }

    /// Returns the URL of the finished profile (installed too, unless `installProfile` is false).
    public func run() async throws -> URL {
        defer { continuation.finish() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = options.profileName
        let display = "-d\(options.displayIndex)"
        let port = "-c\(options.instrumentPort)"
        let quality = "-q\(options.quality)"
        let hiRes = options.hiRes ? ["-H"] : []
        // dispcal and dispread draw patches either on the chosen display or via the web server.
        let patchTarget = options.patchServerPort.map { "-dweb:\($0)" } ?? display

        // -d3: RGB display; -G: optimized (slower, better) point placement;
        // -e/-B: extra white/black patches; -g: grey-axis steps; -f: total patches.
        try await step(.targen, ["-v", "-d3", "-G", "-e4", "-B4", "-g32", "-f\(options.patchCount)", base])

        var readArgs = ["-v"] + hiRes + [patchTarget, port]
        if let cal = options.calibration {
            // -m skips the interactive monitor-control adjustment menu.
            var calArgs = ["-v", "-m", patchTarget, port, quality] + hiRes + ["-g\(cal.gamma)"]
            if let kelvin = cal.whitePointKelvin { calArgs.append("-t\(kelvin)") }
            try await step(.dispcal, calArgs + [base])
            // Measure through the new curves; colprof embeds them as vcgt.
            readArgs += ["-k", "\(base).cal"]
        }
        try await step(.dispread, readArgs + [base])

        // -as: shaper + matrix. Recent macOS no longer reliably honours LUT-based
        // display profiles, and a matrix profile is what a well-behaved display needs anyway.
        try await step(.colprof, ["-v", quality, "-as", "-D", base, "-C", "Profiled with ArgyllCMS", base])

        // -I installs into ~/Library/ColorSync/Profiles and assigns it to the display.
        if options.installProfile {
            try await step(.dispwin, [display, "-I", "\(base).icc"])
        }

        return directory.appendingPathComponent("\(base).icc")
    }

    private func step(_ stage: Stage, _ arguments: [String]) async throws {
        let runner = try ArgyllRunner(tool: stage.rawValue, arguments: arguments, workingDirectory: directory.path)
        current = runner
        defer { current = nil }

        var lastError: String?
        var code: Int32 = -1
        for await event in runner.events {
            if case .error(let message) = event { lastError = message }
            if case .exited(let exitCode) = event { code = exitCode }
            continuation.yield((stage, event))
        }
        guard code == 0 else {
            throw Failure.stageFailed(stage, code: code, lastError: lastError)
        }
    }
}
