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
    /// -N: reuse the instrument's last white-tile calibration if Argyll still considers
    /// it valid, so a run can start with the instrument already on the display.
    public var skipInstrumentCalibrationIfPossible: Bool = false
    /// Colorimeter display type (dispread/dispcal -y). Leave nil for spectrophotometers
    /// and for Argyll's default; use "n" (base, non-refresh) together with a correction matrix.
    public var displayType: String? = nil
    /// Colorimeter correction matrix or spectral set (-X file.ccmx / .ccss), made with
    /// ccxxmake against a spectrophotometer for one display + colorimeter pair.
    public var correctionFile: URL? = nil
    /// Where the patch window goes and how big it is (dispcal/dispread/ccxxmake -P):
    /// horizontal and vertical position 0…1 (0.5 = centre, 1 = bottom/right), scale 1 = default.
    /// A big instrument on a tilted laptop screen wants it low and large.
    public var patchWindow: PatchWindow? = nil

    public struct PatchWindow: Sendable, Equatable {
        public var horizontal: Double = 0.5
        public var vertical: Double = 0.5
        public var scale: Double = 1.0
        public init(horizontal: Double = 0.5, vertical: Double = 0.5, scale: Double = 1.0) {
            self.horizontal = horizontal; self.vertical = vertical; self.scale = scale
        }
        public var argument: String { String(format: "-P%.2f,%.2f,%.1f", horizontal, vertical, scale) }
    }

    /// nil profiles the display as it is. That is the right choice for a Studio Display
    /// sitting in an Apple reference preset: no gamma-table curves, just a description
    /// of what the display does. Set it to run dispcal first and embed vcgt curves.
    public var calibration: Calibration? = nil
    /// If set, dispread serves patches at http://localhost:PORT instead of drawing its
    /// own window. Only useful with a patch renderer that draws in device RGB; a plain
    /// web view is colour-managed and would corrupt the measurement.
    public var patchServerPort: Int? = nil
    /// false leaves the finished .icc in the working directory without installing or
    /// assigning it (dispwin -I). Useful for test runs and for validation-only passes.
    public var installProfile: Bool = true
    /// Provenance written into the ICC file. The description is what System Settings
    /// shows in the Color profile menu; defaults to the profile name.
    public var profileDescription: String? = nil
    /// ICC device model tag (colprof -M), e.g. the display's name.
    public var deviceModel: String? = nil
    /// ICC copyright tag (colprof -C); a good place for the app and instrument.
    public var copyright: String = "Made with ArgyllCMS"

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
    /// Terminate the running tool immediately (app quitting).
    public func kill() { current?.kill() }
    /// Escape lets the tool clean up (restore the display, close its window); if it is
    /// still running two seconds later it is terminated.
    public func abort() {
        guard let runner = current else { return }
        runner.abort()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            runner.kill()
        }
    }

    /// Returns the URL of the finished profile (installed too, unless `installProfile` is false).
    public func run() async throws -> URL {
        defer { continuation.finish() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = options.profileName
        let display = "-d\(options.displayIndex)"
        let port = "-c\(options.instrumentPort)"
        let quality = "-q\(options.quality)"
        var measureFlags: [String] = []
        if options.hiRes { measureFlags.append("-H") }
        if options.skipInstrumentCalibrationIfPossible { measureFlags.append("-N") }
        if let type = options.displayType { measureFlags.append("-y\(type)") }
        if let correction = options.correctionFile { measureFlags += ["-X", correction.path] }
        if let window = options.patchWindow { measureFlags.append(window.argument) }
        // dispcal and dispread draw patches either on the chosen display or via the web server.
        let patchTarget = options.patchServerPort.map { "-dweb:\($0)" } ?? display

        // -d3: RGB display; -G: optimized (slower, better) point placement;
        // -e/-B: extra white/black patches; -g: grey-axis steps; -f: total patches.
        try await step(.targen, ["-v", "-d3", "-G", "-e4", "-B4", "-g32", "-f\(options.patchCount)", base])

        var readArgs = ["-v"] + measureFlags + [patchTarget, port]
        if let cal = options.calibration {
            // -m skips the interactive monitor-control adjustment menu.
            var calArgs = ["-v", "-m", patchTarget, port, quality] + measureFlags + ["-g\(cal.gamma)"]
            if let kelvin = cal.whitePointKelvin { calArgs.append("-t\(kelvin)") }
            try await step(.dispcal, calArgs + [base])
            // Measure through the new curves; colprof embeds them as vcgt.
            readArgs += ["-k", "\(base).cal"]
        }
        try await step(.dispread, readArgs + [base])

        // -as: shaper + matrix. Recent macOS no longer reliably honours LUT-based
        // display profiles, and a matrix profile is what a well-behaved display needs anyway.
        var profArgs = ["-v", quality, "-as", "-D", options.profileDescription ?? base, "-C", options.copyright]
        if let model = options.deviceModel { profArgs += ["-M", model] }
        try await step(.colprof, profArgs + [base])

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
