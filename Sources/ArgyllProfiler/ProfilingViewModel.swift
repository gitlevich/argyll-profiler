import Foundation
import SwiftUI
import ArgyllKit

/// Drives one profiling run for the UI: loads the display/instrument lists, starts
/// the pipeline, mirrors its events into @Published state, and relays the user's
/// "continue" for each prompt back to the session.
@MainActor
final class ProfilingViewModel: ObservableObject {

    // Setup state
    @Published var argyllInstalled = true
    @Published var displays: [Argyll.Display] = []
    @Published var instruments: [Argyll.Instrument] = []
    @Published var selectedDisplay: Int?
    @Published var selectedInstrument: Int?
    @Published var profileName = ""
    @Published var mode: Mode = .profileOnly
    @Published var preset: Preset = .standard
    @Published var whitePoint = WhitePoint.d65
    @Published var gamma = 2.2

    // Run state
    @Published var phase: Phase = .setup
    @Published var stage: ProfilingSession.Stage?
    @Published var progress: (done: Int, total: Int)?
    @Published var currentPrompt: ArgyllPrompt?
    @Published var log: [String] = []
    @Published var result: Result?

    enum Mode: String, CaseIterable, Identifiable {
        case profileOnly = "Profile only"
        case calibrate = "Calibrate + profile"
        var id: String { rawValue }
        var explanation: String {
            switch self {
            case .profileOnly:
                return "Measures the display as it is and builds a profile. Right for a Studio Display left in an Apple reference preset — no gamma curves are loaded."
            case .calibrate:
                return "Adjusts the display toward a target white point and gamma first, then profiles. For displays without trustworthy built-in presets."
            }
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case quick = "Quick"
        case standard = "Standard"
        case thorough = "Thorough"
        var id: String { rawValue }
        var patches: Int { switch self { case .quick: 150; case .standard: 300; case .thorough: 600 } }
        var quality: Character { switch self { case .quick: "l"; case .standard: "m"; case .thorough: "h" } }
        var estimateMinutes: Int { max(1, Int((Double(patches) * 3.0 + 40) / 60).rounded())) }
    }

    enum WhitePoint: String, CaseIterable, Identifiable {
        case native = "Native"
        case d65 = "D65 (6500K)"
        case d50 = "D50 (5000K)"
        var id: String { rawValue }
        var kelvin: Int? { switch self { case .native: nil; case .d65: 6500; case .d50: 5000 } }
    }

    enum Phase: Equatable { case setup, running, finished, failed(String) }

    struct Result {
        var profileURL: URL
        var installed: Bool
        var luminance: Double?
        var whitePointCCT: Int?
    }

    private var session: ProfilingSession?
    private var whitePointXYZ: (Double, Double, Double)?
    private var measuredLuminance: Double?

    var canStart: Bool {
        argyllInstalled && selectedDisplay != nil && selectedInstrument != nil
            && !profileName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var selectedDisplayName: String {
        displays.first { $0.index == selectedDisplay }?.name ?? "display"
    }

    // MARK: setup

    func load() async {
        do {
            let d = try await Argyll.displays()
            let i = try await Argyll.instruments()
            argyllInstalled = true
            displays = d
            instruments = i.filter { $0.name.range(of: "bluetooth|incoming", options: .regularexpression) == nil }
            // Default to the first non-built-in display and the first real instrument.
            selectedDisplay = d.first { !$0.name.localizedCaseInsensitiveContains("built-in") }?.index ?? d.first?.index
            selectedInstrument = instruments.first?.port
            if profileName.isEmpty {
                let stamp = ISO8601DateFormatter.shortDate.string(from: Date())
                let base = (selectedDisplayName.split(separator: ",").first.map(String.init) ?? "Display")
                    .replacingOccurrences(of: " ", with: "")
                profileName = "\(base)_\(stamp)"
            }
        } catch Argyll.Failure.toolNotFound {
            argyllInstalled = false
        } catch {
            argyllInstalled = false
        }
    }

    // MARK: run

    func start() {
        guard let display = selectedDisplay, let instrument = selectedInstrument else { return }
        var options = ProfilingOptions(displayIndex: display,
                                       instrumentPort: instrument,
                                       profileName: profileName.trimmingCharacters(in: .whitespaces))
        options.patchCount = preset.patches
        options.quality = preset.quality
        if mode == .calibrate {
            options.calibration = ProfilingOptions.Calibration(whitePointKelvin: whitePoint.kelvin, gamma: gamma)
        }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArgyllProfiler/runs/\(options.profileName)", isDirectory: true)

        log.removeAll()
        progress = nil
        currentPrompt = nil
        result = nil
        whitePointXYZ = nil
        measuredLuminance = nil
        phase = .running

        let session = ProfilingSession(options: options, directory: dir)
        self.session = session

        Task { [weak self] in
            for await (stage, event) in session.events {
                await self?.handle(stage: stage, event: event)
            }
        }
        Task { [weak self] in
            do {
                let url = try await session.run()
                await self?.finish(url: url, installed: options.installProfile)
            } catch {
                await self?.fail(error)
            }
        }
    }

    func continueFromPrompt() {
        currentPrompt = nil
        Task { await session?.answerPrompt() }
    }

    func cancel() {
        Task { await session?.abort() }
    }

    private func handle(stage: ProfilingSession.Stage, event: ArgyllEvent) {
        self.stage = stage
        switch event {
        case .line(let line):
            log.append("[\(stage)] \(line)")
            if log.count > 2000 { log.removeFirst(log.count - 2000) }
            scrapeMetrics(line)
        case .progress(let done, let total):
            progress = (done, total)
        case .prompt(let prompt):
            currentPrompt = prompt
        case .error(let message):
            log.append("[\(stage)] error: \(message)")
        case .exited:
            if stage == .dispread { progress = nil }
        }
    }

    /// colprof prints the finished profile's luminance and white point; keep them for the summary.
    private func scrapeMetrics(_ line: String) {
        if let m = line.firstMatch(of: try! Regex("Display Luminance = ([0-9.]+)")),
           let v = Double(m[1].substring ?? "") {
            measuredLuminance = v
        }
        if let m = line.firstMatch(of: try! Regex("White point XYZ = ([0-9.]+) ([0-9.]+) ([0-9.]+)")),
           let x = Double(m[1].substring ?? ""), let y = Double(m[2].substring ?? ""), let z = Double(m[3].substring ?? "") {
            whitePointXYZ = (x, y, z)
        }
    }

    private func finish(url: URL, installed: Bool) {
        currentPrompt = nil
        progress = nil
        result = Result(profileURL: url,
                        installed: installed,
                        luminance: measuredLuminance,
                        whitePointCCT: whitePointXYZ.map(Self.cct))
        phase = .finished
    }

    private func fail(_ error: Error) {
        currentPrompt = nil
        progress = nil
        // Esc-driven abort surfaces as a non-zero exit; report it plainly.
        if case ProfilingSession.Failure.stageFailed(let stage, _, let last) = error {
            phase = .failed("\(stage) stopped\(last.map { ": \($0)" } ?? "").")
        } else {
            phase = .failed("\(error)")
        }
    }

    func reset() {
        phase = .setup
        session = nil
    }

    /// Correlated colour temperature from XYZ via McCamy's cubic approximation.
    static func cct(_ xyz: (Double, Double, Double)) -> Int {
        let (X, Y, Z) = xyz
        let sum = X + Y + Z
        guard sum > 0 else { return 0 }
        let x = X / sum, y = Y / sum
        let n = (x - 0.3320) / (0.1858 - y)
        let cct = 449 * pow(n, 3) + 3525 * pow(n, 2) + 6823.3 * n + 5520.33
        return Int(cct.rounded())
    }
}

private extension ISO8601DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
