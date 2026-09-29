import Foundation
import AppKit
import ArgyllKit

/// All app state: discovery, setup choices, and the live run.
@MainActor
final class RunModel: ObservableObject {
    enum Phase: Equatable {
        case setup, running, finished
        case failed(String)
    }

    enum StageState: Equatable { case pending, running, done, failed }

    struct Summary {
        var profileURL: URL
        var installed: Bool
        var luminance: Double?
        var whiteXYZ: [Double]?
        var avgError: Double?
        var peakError: Double?

        var whiteChromaticity: (x: Double, y: Double)? {
            guard let w = whiteXYZ, w.count == 3 else { return nil }
            let sum = w[0] + w[1] + w[2]
            return sum > 0 ? (w[0] / sum, w[1] / sum) : nil
        }

        /// McCamy's approximation from xy. Plenty for a summary line.
        var correlatedColorTemperature: Double? {
            guard let c = whiteChromaticity else { return nil }
            let n = (c.x - 0.3320) / (0.1858 - c.y)
            return 449 * pow(n, 3) + 3525 * pow(n, 2) + 6823.3 * n + 5520.33
        }
    }

    // Discovery
    @Published var displays: [Argyll.Display] = []
    @Published var instruments: [Argyll.Instrument] = []
    @Published var discoveryError: String?
    @Published var discovering = false

    // Setup choices
    @Published var displayIndex = 1
    @Published var instrumentPort = 1
    @Published var profileName = RunModel.defaultProfileName()
    @Published var calibrate = false
    @Published var whitePointKelvin = 6500          // 0 = native
    @Published var gamma = 2.2
    @Published var patchCount = 175
    @Published var quality: Character = "m"
    @Published var installProfile = true
    @Published var skipInstrumentCalibration = false

    // Run state
    @Published var phase: Phase = .setup
    @Published var stages: [ProfilingSession.Stage] = []
    @Published var stageStates: [ProfilingSession.Stage: StageState] = [:]
    @Published var currentStage: ProfilingSession.Stage?
    @Published var prompt: ArgyllPrompt?
    @Published var progress: (done: Int, total: Int)?
    @Published var log: [String] = []
    @Published var summary: Summary?

    private var session: ProfilingSession?
    private var pending = Summary(profileURL: URL(fileURLWithPath: "/"), installed: false)
    private var controlPath: String?
    private var logFile: FileHandle?

    private static let luminanceRegex = try! Regex("Display Luminance = ([0-9.]+)")
    private static let whiteRegex = try! Regex("White point XYZ = ([0-9.]+) ([0-9.]+) ([0-9.]+)")
    private static let fitRegex = try! Regex("peak err = ([0-9.]+), avg err = ([0-9.]+)")

    // MARK: - Names and paths

    static func defaultProfileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Display_" + f.string(from: Date())
    }

    static func shortName(_ argyllName: String) -> String {
        argyllName.components(separatedBy: ", at ").first ?? argyllName
    }

    var selectedDisplayName: String {
        displays.first { $0.index == displayIndex }.map { Self.shortName($0.name) } ?? "display \(displayIndex)"
    }

    static func runsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ArgyllApp/Runs", isDirectory: true)
    }

    // MARK: - Test harness (launch arguments)

    /// `--control PATH` answers prompts when PATH appears; `--log PATH` mirrors the log to a
    /// file; `--autostart` runs discovery and starts immediately. The rest preset the form.
    func configure(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        controlPath = value("--control")
        if let path = value("--log") {
            FileManager.default.createFile(atPath: path, contents: nil)
            logFile = FileHandle(forWritingAtPath: path)
        }
        if let d = value("--display").flatMap(Int.init) { displayIndex = d }
        if let p = value("--patches").flatMap(Int.init) { patchCount = p }
        if let n = value("--name") { profileName = n }
        if arguments.contains("--no-install") { installProfile = false }
        if arguments.contains("--skip-cal") { skipInstrumentCalibration = true }
        if arguments.contains("--autostart") {
            Task {
                await discover()
                start()
            }
        }
    }

    // MARK: - Discovery

    func discoverIfNeeded() async {
        if displays.isEmpty && !discovering { await discover() }
    }

    func discover() async {
        discovering = true
        defer { discovering = false }
        do {
            displays = try await Argyll.displays()
            instruments = try await Argyll.instruments()
            discoveryError = nil
            if !displays.contains(where: { $0.index == displayIndex }) {
                displayIndex = displays.first { !$0.name.localizedCaseInsensitiveContains("built-in") }?.index
                    ?? displays.first?.index ?? 1
            }
            if !instruments.contains(where: { $0.port == instrumentPort }) {
                instrumentPort = instruments.first { $0.name.localizedCaseInsensitiveContains("i1") }?.port
                    ?? instruments.first?.port ?? 1
            }
            note("DISCOVERED displays=\(displays.count) instruments=\(instruments.count) argyll=\(Argyll.location ?? "not found")")
        } catch {
            discoveryError = "\(error)"
            note("DISCOVERY FAILED \(error)")
        }
    }

    // MARK: - Run

    func start() {
        var options = ProfilingOptions(displayIndex: displayIndex, instrumentPort: instrumentPort, profileName: profileName)
        options.patchCount = patchCount
        options.quality = quality
        options.installProfile = installProfile
        options.skipInstrumentCalibrationIfPossible = skipInstrumentCalibration
        if calibrate {
            options.calibration = ProfilingOptions.Calibration(
                whitePointKelvin: whitePointKelvin == 0 ? nil : whitePointKelvin,
                gamma: gamma)
        }

        let directory = Self.runsDirectory().appendingPathComponent(profileName, isDirectory: true)
        let session = ProfilingSession(options: options, directory: directory)
        self.session = session

        attach(stages: [.targen] + (calibrate ? [.dispcal] : []) + [.dispread, .colprof] + (installProfile ? [.dispwin] : []),
               profileURL: directory.appendingPathComponent("\(profileName).icc"),
               installed: installProfile,
               events: session.events) {
            try await session.run()
        }
    }

    /// Wires a run into the model. Separate from `start()` so tests can feed a synthetic
    /// event stream and a run closure without Argyll or an instrument.
    func attach(stages: [ProfilingSession.Stage],
                profileURL: URL,
                installed: Bool,
                events: AsyncStream<(ProfilingSession.Stage, ArgyllEvent)>,
                run: @escaping @Sendable () async throws -> URL) {
        self.stages = stages
        stageStates = Dictionary(uniqueKeysWithValues: stages.map { ($0, StageState.pending) })
        currentStage = nil
        prompt = nil
        progress = nil
        log = []
        summary = nil
        pending = Summary(profileURL: profileURL, installed: installed)
        phase = .running
        note("PHASE running")

        let consumer = Task { [weak self] in
            for await (stage, event) in events {
                self?.handle(stage, event)
            }
        }
        Task { [weak self] in
            // The summary is harvested from events, so every event must be handled before
            // the run is declared finished, whichever of the two completes first.
            do {
                let url = try await run()
                await consumer.value
                self?.finish(url)
            } catch {
                await consumer.value
                self?.fail("\(error)")
            }
        }
    }

    func continueAfterPrompt() {
        guard let session else { return }
        prompt = nil
        note("ANSWERED")
        Task { await session.answerPrompt() }
    }

    func cancel() {
        guard let session else { return }
        note("CANCEL")
        Task { await session.abort() }
    }

    func reset() {
        session = nil
        phase = .setup
        prompt = nil
        progress = nil
        profileName = Self.defaultProfileName()
    }

    // MARK: - Event handling

    private func handle(_ stage: ProfilingSession.Stage, _ event: ArgyllEvent) {
        if currentStage != stage {
            currentStage = stage
            stageStates[stage] = .running
            progress = nil
            note("STAGE \(stage.rawValue)")
        }
        switch event {
        case .line(let line):
            append("[\(stage.rawValue)] \(line)")
            if stage == .colprof { harvest(line) }
        case .progress(let done, let total):
            progress = (done, total)
        case .prompt(let p):
            prompt = p
            note("PROMPT \(p)")
            watchControlFile()
        case .error(let message):
            append("[\(stage.rawValue)] ERROR \(message)")
        case .exited(let code):
            stageStates[stage] = code == 0 ? .done : .failed
            note("EXIT \(stage.rawValue) \(code)")
        }
    }

    private func harvest(_ line: String) {
        if let m = line.firstMatch(of: Self.luminanceRegex), let v = Double(m[1].substring ?? "") {
            pending.luminance = v
        }
        if let m = line.firstMatch(of: Self.whiteRegex) {
            let xyz = (1...3).compactMap { Double(m[$0].substring ?? "") }
            if xyz.count == 3 { pending.whiteXYZ = xyz }
        }
        if let m = line.firstMatch(of: Self.fitRegex),
           let peak = Double(m[1].substring ?? ""), let avg = Double(m[2].substring ?? "") {
            pending.peakError = peak
            pending.avgError = avg
        }
    }

    private func finish(_ url: URL) {
        pending.profileURL = url
        summary = pending
        phase = .finished
        note("PHASE finished \(url.path)")
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        note("PHASE failed \(message)")
    }

    /// Test hook: when a prompt is showing and `--control PATH` was given, the appearance
    /// of PATH counts as the user pressing Continue.
    private func watchControlFile() {
        guard let path = controlPath else { return }
        Task { [weak self] in
            while let model = self, model.prompt != nil {
                if FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                    model.continueAfterPrompt()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Log

    private func append(_ line: String) {
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
        logFile?.write(Data((line + "\n").utf8))
    }

    private func note(_ line: String) {
        append("• " + line)
    }
}
