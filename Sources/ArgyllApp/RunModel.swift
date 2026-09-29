import Foundation
import AppKit
import ArgyllKit

/// All app state: discovery, setup choices, the live run, and profile comparison.
@MainActor
final class RunModel: ObservableObject {
    enum Phase: Equatable {
        case setup, running, finished, compare
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

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    // Discovery
    @Published var displays: [Argyll.Display] = []
    @Published var instruments: [Argyll.Instrument] = []
    @Published var discoveryError: String?
    @Published var discovering = false

    // Setup choices
    @Published var displayIndex = 1 { didSet { refreshSuggestedName() } }
    @Published var instrumentPort = 1 { didSet { refreshSuggestedName() } }
    @Published var profileName = ""
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

    // Compare
    @Published var compareProfiles: [InstalledProfile] = []
    @Published var compareA: URL?
    @Published var compareB: URL?
    @Published var activeProfile: URL?
    @Published var referenceImage: NSImage? { didSet { rerender() } }
    /// `referenceImage` converted through `activeProfile`, the image actually shown.
    @Published var renderedImage: NSImage?
    @Published var compareDisplayName = ""
    private var compareDisplayID: CGDirectDisplayID?
    /// Whatever the display was using when the last run started.
    private(set) var previousProfileURL: URL?

    private var session: ProfilingSession?
    private var pending = Summary(profileURL: URL(fileURLWithPath: "/"), installed: false)
    private var controlPath: String?
    private var logFile: FileHandle?
    private var nameIsCustom = false
    private var displayPreset = false

    private static let luminanceRegex = try! Regex("Display Luminance = ([0-9.]+)")
    private static let whiteRegex = try! Regex("White point XYZ = ([0-9.]+) ([0-9.]+) ([0-9.]+)")
    private static let fitRegex = try! Regex("peak err = ([0-9.]+), avg err = ([0-9.]+)")

    init() {
        profileName = suggestedProfileName()
    }

    // MARK: - Names and provenance

    static func shortName(_ argyllName: String) -> String {
        argyllName.components(separatedBy: ", at ").first ?? argyllName
    }

    /// "usb1: (X-Rite i1 Pro 2)" → "i1 Pro 2"; the i1d3 family (i1 DisplayPro, ColorMunki
    /// Display, Calibrite Display SL/Pro HL/Plus HL) all report as "i1 DisplayPro, ColorMunki Display".
    static func instrumentName(_ argyllName: String) -> String {
        var s = argyllName
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            s = String(s[s.index(after: open)..<close])
        }
        s = s.replacingOccurrences(of: "X-Rite ", with: "").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("i1 DisplayPro") { return "i1 DisplayPro family" }
        return s
    }

    enum InstrumentKind: String { case spectrophotometer, colorimeter, unknown }

    /// X-Rite's names hide which is which: "i1 Pro" is the spectrophotometer, "i1 DisplayPro" the colorimeter.
    static func instrumentKind(_ argyllName: String) -> InstrumentKind {
        let n = argyllName.lowercased()
        if n.contains("displaypro") || n.contains("colormunki display") || n.contains("spyder")
            || n.contains("huey") || n.contains("dtp92") || n.contains("dtp94") || n.contains("smile")
            || n.contains("i1 display") || n.contains("k-10") || n.contains("chroma") {
            return .colorimeter
        }
        if n.contains("i1 pro") || n.contains("i1pro") || n.contains("colormunki") || n.contains("spectrolino")
            || n.contains("dtp41") || n.contains("dtp20") || n.contains("dtp22") || n.contains("dtp51")
            || n.contains("i1 monitor") || n.contains("spectro") {
            return .spectrophotometer
        }
        return .unknown
    }

    /// User-given names for instruments Argyll can't tell apart, keyed by Argyll's name.
    @Published var instrumentNicknames: [String: String] = UserDefaults.standard.dictionary(forKey: "instrumentNicknames") as? [String: String] ?? [:] {
        didSet {
            UserDefaults.standard.set(instrumentNicknames, forKey: "instrumentNicknames")
            refreshSuggestedName()
        }
    }

    /// "Colorimeter: Calibrite Display Plus HL" or "Spectrophotometer: i1 Pro 2", for pickers and prompts.
    func instrumentLabel(_ instrument: Argyll.Instrument) -> String {
        let name = instrumentNicknames[instrument.name] ?? Self.instrumentName(instrument.name)
        switch Self.instrumentKind(instrument.name) {
        case .spectrophotometer: return "Spectrophotometer: \(name)"
        case .colorimeter: return "Colorimeter: \(name)"
        case .unknown: return name
        }
    }

    var selectedInstrument: Argyll.Instrument? { instruments.first { $0.port == instrumentPort } }

    func setNickname(_ nickname: String) {
        guard let argyllName = selectedInstrument?.name else { return }
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { instrumentNicknames.removeValue(forKey: argyllName) } else { instrumentNicknames[argyllName] = trimmed }
    }

    private static func token(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    var selectedDisplayName: String {
        displays.first { $0.index == displayIndex }.map { Self.shortName($0.name) } ?? "display \(displayIndex)"
    }

    /// Nickname if the user gave one, else the cleaned-up Argyll name.
    var selectedInstrumentName: String {
        guard let i = selectedInstrument else { return "instrument" }
        return instrumentNicknames[i.name] ?? Self.instrumentName(i.name)
    }

    /// Name plus kind, for the provenance line: "Calibrite Display Plus HL colorimeter".
    var selectedInstrumentDescription: String {
        guard let i = selectedInstrument else { return "instrument" }
        let kind = Self.instrumentKind(i.name)
        return kind == .unknown ? selectedInstrumentName : "\(selectedInstrumentName) \(kind.rawValue)"
    }

    /// StudioDisplay_i1Pro2_2026-09-28_1830
    func suggestedProfileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return [Self.token(selectedDisplayName), Self.token(selectedInstrumentName), f.string(from: date)]
            .filter { !$0.isEmpty }.joined(separator: "_")
    }

    /// Called from the name field: once the user types their own name, stop suggesting.
    func profileNameEdited(_ text: String) {
        nameIsCustom = text != suggestedProfileName()
    }

    private func refreshSuggestedName() {
        if !nameIsCustom { profileName = suggestedProfileName() }
    }

    /// Long-form provenance for the ICC description tag. ASCII only: colprof writes the
    /// v2 description tag as 7-bit text and anything else becomes "?" (BUGS.md #3).
    func profileDescription(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let mode = calibrate ? "calibrated \(whitePointKelvin == 0 ? "native" : "\(whitePointKelvin) K") gamma \(gamma)" : "profile only"
        let text = "\(selectedDisplayName), \(selectedInstrumentDescription), \(f.string(from: date)) (Argyll Profiler \(Self.appVersion), \(mode), \(patchCount) patches)"
        return String(text.unicodeScalars.map { $0.isASCII ? Character($0) : "-" })
    }

    static func runsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ArgyllApp/Runs", isDirectory: true)
    }

    func selectedDisplayCGID() -> CGDirectDisplayID? {
        displays.first { $0.index == displayIndex }.flatMap { DisplayProfiles.displayID(forArgyllName: $0.name) }
    }

    // MARK: - Test harness (launch arguments)

    /// `--control PATH` answers prompts when PATH appears; `--log PATH` mirrors the log to a
    /// file; `--autostart` runs discovery and starts immediately; `--compare` opens the
    /// compare screen after discovery. The rest preset the form.
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
        if let d = value("--display").flatMap(Int.init) { displayIndex = d; displayPreset = true }
        if let p = value("--patches").flatMap(Int.init) { patchCount = p }
        if let n = value("--name") { profileName = n; nameIsCustom = true }
        if arguments.contains("--no-install") { installProfile = false }
        if arguments.contains("--skip-cal") { skipInstrumentCalibration = true }
        if arguments.contains("--autostart") {
            Task { await discover(); start() }
        } else if arguments.contains("--compare") {
            Task { await discover(); openCompare() }
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
            let firstDiscovery = displays.isEmpty && !displayPreset
            displays = try await Argyll.displays()
            instruments = try await Argyll.instruments()
            discoveryError = nil
            // First time through, prefer an external display: that is what people profile.
            if firstDiscovery || !displays.contains(where: { $0.index == displayIndex }) {
                displayIndex = displays.first { !$0.name.localizedCaseInsensitiveContains("built-in") }?.index
                    ?? displays.first?.index ?? 1
            }
            if !instruments.contains(where: { $0.port == instrumentPort }) {
                instrumentPort = instruments.first { $0.name.localizedCaseInsensitiveContains("i1") }?.port
                    ?? instruments.first?.port ?? 1
            }
            refreshSuggestedName()
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
        options.profileDescription = profileDescription()
        options.deviceModel = selectedDisplayName
        options.copyright = "Made with Argyll Profiler \(Self.appVersion) and ArgyllCMS, measured with \(selectedInstrumentDescription)"
        if calibrate {
            options.calibration = ProfilingOptions.Calibration(
                whitePointKelvin: whitePointKelvin == 0 ? nil : whitePointKelvin,
                gamma: gamma)
        }

        if let id = selectedDisplayCGID() {
            previousProfileURL = DisplayProfiles.currentProfileURL(for: id)
            note("PREVIOUS \(previousProfileURL?.lastPathComponent ?? "none")")
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
        nameIsCustom = false
        profileName = suggestedProfileName()
    }

    // MARK: - Compare

    /// Opens the compare screen for the selected display, preselecting the profile from
    /// the last run against whatever the display used before it.
    func openCompare() {
        guard let id = selectedDisplayCGID() else { return }
        compareDisplayID = id
        compareDisplayName = selectedDisplayName
        compareProfiles = DisplayProfiles.availableProfiles(for: id)
        activeProfile = DisplayProfiles.currentProfileURL(for: id)
        let factory = compareProfiles.first { $0.isFactory }?.url
        let installedNew = summary.flatMap { s in compareProfiles.first { $0.url.lastPathComponent == s.profileURL.lastPathComponent }?.url }
        compareA = installedNew ?? activeProfile ?? factory
        compareB = previousProfileURL ?? compareProfiles.first { $0.url != compareA }?.url ?? factory
        if referenceImage == nil { referenceImage = TestImage.make() } else { rerender() }
        phase = .compare
        note("COMPARE active=\(activeProfile?.lastPathComponent ?? "factory") A=\(compareA?.lastPathComponent ?? "-") B=\(compareB?.lastPathComponent ?? "-")")
    }

    func activate(_ url: URL?) {
        guard let id = compareDisplayID else { return }
        let factory = compareProfiles.first { $0.isFactory }?.url
        let target = (url == factory) ? nil : url          // nil = revert to factory, the clean way
        if DisplayProfiles.setProfile(target, for: id) {
            activeProfile = url ?? factory
            note("ACTIVATED \(activeProfile?.lastPathComponent ?? "factory")")
        } else {
            note("ACTIVATE FAILED \(url?.lastPathComponent ?? "factory")")
        }
        rerender()
    }

    private func rerender() {
        guard let image = referenceImage else { renderedImage = nil; return }
        renderedImage = ProfileRenderer.render(image, through: activeProfile)
    }

    func toggleCompare() {
        activate(activeProfile == compareA ? compareB : compareA)
    }

    func profileName(for url: URL?) -> String {
        guard let url else { return "—" }
        return compareProfiles.first { $0.url == url }?.name ?? url.deletingPathExtension().lastPathComponent
    }

    func compactLabel(for url: URL?) -> String {
        guard let url else { return "—" }
        guard let p = compareProfiles.first(where: { $0.url == url }) else { return url.deletingPathExtension().lastPathComponent }
        return Self.compactLabel(p)
    }

    /// Menu-sized label: screen · instrument · date. Built from the description this app
    /// writes ("Screen, Instrument kind, Date (details)") and from the two earlier formats
    /// (" - " and " ? " separators); anything else shows as it is.
    static func compactLabel(_ p: InstalledProfile) -> String {
        if p.isFactory { return "\(p.name) (Apple factory)" }
        var s = p.name
        if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) }
        let separator = [" - ", " ? ", " · ", ", "].first { s.contains($0) }
        guard let separator else { return p.name }
        var parts = s.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
        parts = parts.filter { !$0.hasPrefix("Argyll Profiler") && !$0.contains("patches") && !$0.hasPrefix("profile only") && !$0.hasPrefix("calibrated") }
        parts = parts.map { $0.replacingOccurrences(of: "i1 DisplayPro, ColorMunki Display", with: "i1 DisplayPro") }
        parts = parts.map { $0.replacingOccurrences(of: " colorimeter", with: "").replacingOccurrences(of: " spectrophotometer", with: "") }
        if separator == ", " && parts.count > 3 { parts = Array(parts.prefix(3)) }   // date may hold no comma; details already cut
        return parts.isEmpty ? p.name : parts.prefix(3).joined(separator: " · ")
    }

    func chooseReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            referenceImage = image
        }
    }

    func useReferenceImage(at url: URL) {
        if let image = NSImage(contentsOf: url) { referenceImage = image }
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
