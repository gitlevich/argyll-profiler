import Foundation
import AppKit
import ArgyllKit

/// All app state: discovery, setup choices, the live run, and profile comparison.
@MainActor
final class RunModel: ObservableObject {
    enum Phase: Equatable {
        case setup, running, finished, compare, correcting, corrected
        case failed(String)
    }

    enum StageState: Equatable { case pending, running, done, failed }

    struct Summary {
        var profileURL: URL
        var installed: Bool
        /// Set when installation was refused because the measured white is implausible.
        var implausibleWhite: (x: Double, y: Double)?
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

    // Setup choices, remembered between launches.
    private static let store = UserDefaults.standard
    @Published var displayIndex = 1 { didSet { refreshSuggestedName(); rememberSelection() } }
    @Published var instrumentPort = 1 { didSet { refreshSuggestedName(); rememberSelection() } }
    @Published var profileName = ""
    @Published var calibrate = store.bool(forKey: "calibrate") { didSet { Self.store.set(calibrate, forKey: "calibrate") } }
    @Published var whitePointKelvin = store.object(forKey: "whitePointKelvin") as? Int ?? 6500 { didSet { Self.store.set(whitePointKelvin, forKey: "whitePointKelvin") } }   // 0 = native
    @Published var gamma = store.object(forKey: "gamma") as? Double ?? 2.2 { didSet { Self.store.set(gamma, forKey: "gamma") } }
    @Published var patchCount = store.object(forKey: "patchCount") as? Int ?? 175 { didSet { Self.store.set(patchCount, forKey: "patchCount") } }
    @Published var quality: Character = Character(store.string(forKey: "quality") ?? "m") { didSet { Self.store.set(String(quality), forKey: "quality") } }
    @Published var installProfile = store.object(forKey: "installProfile") as? Bool ?? true { didSet { Self.store.set(installProfile, forKey: "installProfile") } }
    /// Patch window: vertical position (0 top, 0.5 centre, 1 bottom) and scale (1 normal, 2 large, 3 huge).
    @Published var patchVertical = store.object(forKey: "patchVertical") as? Double ?? 0.5 { didSet { Self.store.set(patchVertical, forKey: "patchVertical") } }
    @Published var patchScale = store.object(forKey: "patchScale") as? Double ?? 1.0 { didSet { Self.store.set(patchScale, forKey: "patchScale") } }

    var patchWindow: ProfilingOptions.PatchWindow? {
        (patchVertical == 0.5 && patchScale == 1.0) ? nil : ProfilingOptions.PatchWindow(horizontal: 0.5, vertical: patchVertical, scale: patchScale)
    }
    @Published var skipInstrumentCalibration = store.bool(forKey: "skipInstrumentCalibration") { didSet { Self.store.set(skipInstrumentCalibration, forKey: "skipInstrumentCalibration") } }

    private func rememberSelection() {
        if let d = displays.first(where: { $0.index == displayIndex }) { Self.store.set(Self.shortName(d.name), forKey: "lastDisplay") }
        if let i = selectedInstrument { Self.store.set(i.name, forKey: "lastInstrument") }
    }

    // Run state
    @Published var phase: Phase = .setup
    @Published var stages: [ProfilingSession.Stage] = []
    @Published var stageStates: [ProfilingSession.Stage: StageState] = [:]
    @Published var currentStage: ProfilingSession.Stage?
    @Published var prompt: ArgyllPrompt?
    @Published var progress: (done: Int, total: Int)?
    @Published var log: [String] = []
    @Published var summary: Summary?

    // Correction matrix
    @Published var displayTechnology = store.string(forKey: "displayTechnology") ?? "u" { didSet { Self.store.set(displayTechnology, forKey: "displayTechnology") } }
    @Published var correctionStep: CorrectionSession.Step?
    @Published var correctionStarted = false
    @Published var correctionResult: CorrectionSession.Result?
    private var correction: CorrectionSession?

    static let displayTechnologies: [(code: String, name: String)] = [
        ("u", "Unknown / other"),
        ("s", "LCD, PFS phosphor, IPS (Apple Studio Display, iMac, MacBook Pro)"),
        ("r", "LCD, PFS phosphor"),
        ("e", "LCD, white LED"),
        ("h", "LCD, RG phosphor"),
        ("b", "LCD, RGB LED"),
        ("o", "OLED"),
        ("w", "WOLED"),
    ]

    var spectrometer: Argyll.Instrument? { instruments.first { Self.instrumentKind($0.name) == .spectrophotometer } }
    var canMakeCorrection: Bool {
        selectedInstrument.map { Self.instrumentKind($0.name) == .colorimeter } == true && spectrometer != nil
    }
    var spectrometerName: String {
        spectrometer.map { nickname(for: $0) ?? Self.instrumentName($0.name) } ?? "spectrophotometer"
    }

    /// Which instrument the current prompt is about.
    var promptInstrumentName: String {
        if phase == .correcting, correctionStep == .spectrometer { return spectrometerName }
        return selectedInstrumentName
    }

    func openCorrection() {
        correctionStarted = false
        correctionResult = nil
        correctionStep = nil
        prompt = nil
        progress = nil
        log = []
        phase = .correcting
    }

    func startCorrection() {
        guard let colorimeter = selectedInstrument, let spectro = spectrometer else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = Self.correctionsDirectory()
            .appendingPathComponent("\(Self.token(selectedDisplayName))_\(Self.token(selectedInstrumentName)).ccmx")
        var options = CorrectionOptions(displayIndex: displayIndex, colorimeterPort: colorimeter.port, spectrometerPort: spectro.port,
                                        displayName: selectedDisplayName,
                                        descriptor: "\(selectedInstrumentName) on \(selectedDisplayName), \(spectrometerName) reference, \(f.string(from: Date()))",
                                        outputURL: url)
        options.displayTechnology = displayTechnology
        options.patchWindow = patchWindow
        let session = CorrectionSession(options: options)
        correction = session
        correctionStarted = true
        note("CORRECTION start colorimeter=\(colorimeter.port) spectrometer=\(spectro.port) tech=\(displayTechnology)")

        let consumer = Task { [weak self] in
            for await event in session.events { self?.handleCorrection(event) }
        }
        Task { [weak self] in
            do {
                let result = try await session.run()
                await consumer.value
                self?.correctionResult = result
                self?.phase = .corrected
                self?.note("CORRECTION done avg=\(result.fitAverage ?? -1) max=\(result.fitMax ?? -1)")
            } catch {
                await consumer.value
                self?.fail("\(error)")
            }
        }
    }

    private func handleCorrection(_ event: CorrectionSession.Event) {
        switch event {
        case .line(let line): append("[ccxxmake] \(line)")
        case .step(let step): correctionStep = step; progress = nil; note("CORRECTION step \(step.rawValue)")
        case .progress(let done, let total): progress = (done, total)
        case .prompt(let p): prompt = p; note("PROMPT \(p)"); watchControlFile()
        case .exited(let code): note("EXIT ccxxmake \(code)")
        }
    }

    func cancelCorrection() {
        Task { await correction?.abort() }
    }

    /// Argyll tools run in their own session and would outlive the app. Called from the
    /// app's termination hook so quitting never leaves a measurement running headless.
    func terminateChildren() {
        let session = self.session
        let correction = self.correction
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await session?.kill()
            await correction?.abort()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // Compare
    @Published var compareProfiles: [InstalledProfile] = []
    /// Changing the menu of the side that is showing re-renders through the new choice at once.
    @Published var compareA: URL? { didSet { if oldValue != nil, activeProfile == oldValue, compareA != oldValue { activate(compareA) } } }
    @Published var compareB: URL? { didSet { if oldValue != nil, activeProfile == oldValue, compareB != oldValue { activate(compareB) } } }
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

    /// Nicknames are keyed by the instrument model ("i1 DisplayPro family"), not by Argyll's
    /// port name ("hid33: (…)"), which changes every time the device is replugged.
    func nickname(for instrument: Argyll.Instrument) -> String? {
        instrumentNicknames[Self.instrumentName(instrument.name)] ?? instrumentNicknames[instrument.name]
    }

    /// "Colorimeter: Calibrite Display Plus HL" or "Spectrophotometer: i1 Pro 2", for pickers and prompts.
    func instrumentLabel(_ instrument: Argyll.Instrument) -> String {
        let name = nickname(for: instrument) ?? Self.instrumentName(instrument.name)
        switch Self.instrumentKind(instrument.name) {
        case .spectrophotometer: return "Spectrophotometer: \(name)"
        case .colorimeter: return "Colorimeter: \(name)"
        case .unknown: return name
        }
    }

    var selectedInstrument: Argyll.Instrument? { instruments.first { $0.port == instrumentPort } }

    func setNickname(_ nickname: String) {
        guard let instrument = selectedInstrument else { return }
        let key = Self.instrumentName(instrument.name)
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        var names = instrumentNicknames
        names.removeValue(forKey: instrument.name)                 // retire any old port-keyed entry
        if trimmed.isEmpty || trimmed == key { names.removeValue(forKey: key) } else { names[key] = trimmed }
        instrumentNicknames = names
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
        return nickname(for: i) ?? Self.instrumentName(i.name)
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

    /// Existing profile names the user might want to reuse (a re-run replaces that file), newest first.
    var existingProfileNames: [String] {
        guard let id = selectedDisplayCGID() else { return [] }
        return DisplayProfiles.availableProfiles(for: id)
            .filter { !$0.isFactory }
            .map { $0.url.deletingPathExtension().lastPathComponent }
            .prefix(10).map { $0 }
    }

    var profileNameReplacesExisting: Bool { existingProfileNames.contains(profileName) }

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
        let corrected = correctionFile != nil ? ", matrix-corrected" : ""
        let text = "\(selectedDisplayName), \(selectedInstrumentDescription), \(f.string(from: date)) (Argyll Profiler \(Self.appVersion), \(mode), \(patchCount) patches\(corrected))"
        return String(text.unicodeScalars.map { $0.isASCII ? Character($0) : "-" })
    }

    static func correctionsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ArgyllApp/Corrections", isDirectory: true)
    }

    /// The correction matrix for the selected display + colorimeter, if one has been made:
    /// Corrections/<DisplayToken>_<InstrumentToken>.ccmx, e.g. StudioDisplay_CalibriteDisplayPlusHL.ccmx.
    var correctionFile: URL? {
        guard let i = selectedInstrument, Self.instrumentKind(i.name) == .colorimeter else { return nil }
        let url = Self.correctionsDirectory()
            .appendingPathComponent("\(Self.token(selectedDisplayName))_\(Self.token(selectedInstrumentName)).ccmx")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Descriptor line inside the .ccmx, for the setup screen.
    var correctionDescription: String? {
        guard let url = correctionFile, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("DESCRIPTOR") {
            return line.replacingOccurrences(of: "DESCRIPTOR", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        return url.lastPathComponent
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
            // Argyll lists every serial port as a possible instrument; on a Mac those are
            // Bluetooth and audio devices, never a colour instrument. USB/HID entries only.
            instruments = try await Argyll.instruments().filter { !$0.name.hasPrefix("/dev/") }
            discoveryError = nil
            // First time through, prefer what was used last, else an external display.
            if firstDiscovery || !displays.contains(where: { $0.index == displayIndex }) {
                let last = Self.store.string(forKey: "lastDisplay")
                displayIndex = displays.first { Self.shortName($0.name) == last }?.index
                    ?? displays.first { !$0.name.localizedCaseInsensitiveContains("built-in") }?.index
                    ?? displays.first?.index ?? 1
            }
            if firstDiscovery || !instruments.contains(where: { $0.port == instrumentPort }) {
                let last = Self.store.string(forKey: "lastInstrument")
                instrumentPort = instruments.first { $0.name == last }?.port
                    ?? instruments.first { $0.name.localizedCaseInsensitiveContains("i1") }?.port
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
        options.patchWindow = patchWindow
        if let correction = correctionFile {
            options.displayType = "n"              // the matrix was made on the base calibration
            options.correctionFile = correction
        }
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
            // Measure the display through Apple's own profile, not through an earlier
            // correction. Installing assigns the new profile afterwards; a test run
            // without installing puts the previous one back.
            DisplayProfiles.setProfile(nil, for: id)
            note("ASSIGNED factory profile for the run")
        }

        let directory = Self.runsDirectory().appendingPathComponent(profileName, isDirectory: true)
        let session = ProfilingSession(options: options, directory: directory)
        self.session = session

        attach(stages: [.targen] + (calibrate ? [.dispcal] : []) + [.dispread, .colprof] + (installProfile ? [.dispwin] : []),
               profileURL: directory.appendingPathComponent("\(profileName).icc"),
               installed: installProfile,
               events: session.events) { [weak self] in
            let url = try await session.run()
            if let white = await session.skippedInstall {
                await MainActor.run { self?.pending.installed = false; self?.pending.implausibleWhite = white }
            }
            return url
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
        prompt = nil
        note("ANSWERED")
        if phase == .correcting, let correction {
            Task { await correction.answerPrompt() }
        } else if let session {
            Task { await session.answerPrompt() }
        }
    }

    func cancel() {
        guard let session else { return }
        note("CANCEL")
        Task { await session.abort() }
    }

    func reset() {
        session = nil
        correction = nil
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
        // Always start by showing A.
        if activeProfile != compareA { activate(compareA) }
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
        if !pending.installed { restorePreviousProfile() }
        if let w = pending.implausibleWhite { note("NOT INSTALLED: white x \(w.x) y \(w.y)") }
        phase = .finished
        note("PHASE finished \(url.path)")
    }

    private func fail(_ message: String) {
        if phase == .running { restorePreviousProfile() }
        phase = .failed(message)
        note("PHASE failed \(message)")
    }

    private func restorePreviousProfile() {
        guard let id = selectedDisplayCGID() else { return }
        let factory = DisplayProfiles.factoryProfile(for: id)?.url
        DisplayProfiles.setProfile(previousProfileURL == factory ? nil : previousProfileURL, for: id)
        note("RESTORED \(previousProfileURL?.lastPathComponent ?? "factory")")
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
