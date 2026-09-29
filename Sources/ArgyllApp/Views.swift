import SwiftUI
import AppKit
import ArgyllKit

struct RootView: View {
    @EnvironmentObject var model: RunModel

    var body: some View {
        Group {
            switch model.phase {
            case .setup: SetupView()
            case .running: RunView()
            case .finished: ResultsView()
            case .compare: CompareView()
            case .correcting: CorrectionView()
            case .corrected: CorrectionDoneView()
            case .failed(let message): FailedView(message: message)
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 700, idealHeight: 900)
        .task { await model.discoverIfNeeded() }
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var model: RunModel
    @State private var nicknameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Hardware") {
                    Picker("Display", selection: $model.displayIndex) {
                        ForEach(model.displays, id: \.index) { d in
                            Text(RunModel.shortName(d.name)).tag(d.index)
                        }
                    }
                    Picker("Instrument", selection: $model.instrumentPort) {
                        ForEach(model.instruments, id: \.port) { i in
                            Text(model.instrumentLabel(i)).tag(i.port)
                        }
                    }
                    if model.selectedInstrument != nil {
                        LabeledContent("Call it") {
                            HStack {
                                if nicknameDraft != model.selectedInstrumentName {
                                    Button("Save") { model.setNickname(nicknameDraft) }.controlSize(.small)
                                }
                                TextField("", text: $nicknameDraft, prompt: Text("a name of your own"))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 260)
                                    .onSubmit { model.setNickname(nicknameDraft) }
                                    .onAppear { nicknameDraft = model.selectedInstrumentName }
                                    .onChange(of: model.instrumentPort) { _ in nicknameDraft = model.selectedInstrumentName }
                            }
                        }
                        .font(.callout)
                    }
                    if model.selectedInstrument.map({ RunModel.instrumentKind($0.name) }) == .colorimeter {
                        HStack(alignment: .firstTextBaseline) {
                            if let correction = model.correctionDescription {
                                Label("Correction matrix: \(correction)", systemImage: "checkmark.seal")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Label("No correction matrix for this colorimeter on this display; Argyll's generic calibration will be used. Saturated colours may be off.", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.canMakeCorrection {
                                Button(model.correctionDescription == nil ? "Make matrix…" : "Remake matrix…") { model.openCorrection() }
                                    .controlSize(.small)
                            } else {
                                Text("Connect a spectrophotometer to make one.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    HStack {
                        if let error = model.discoveryError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else if model.instruments.isEmpty && !model.discovering {
                            Text("No instrument found. Plug in the i1Pro 2 and rescan.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.discovering ? "Scanning…" : "Rescan") {
                            Task { await model.discover() }
                        }
                        .disabled(model.discovering)
                    }
                }

                Section("Target") {
                    HStack {
                        TextField("Profile name", text: $model.profileName)
                            .onChange(of: model.profileName) { model.profileNameEdited($0) }
                        Menu {
                            Button(model.suggestedProfileName()) { model.profileName = model.suggestedProfileName() }
                            if !model.existingProfileNames.isEmpty {
                                Divider()
                                ForEach(model.existingProfileNames, id: \.self) { name in
                                    Button(name) { model.profileName = name }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Suggested name, or an existing profile to replace")
                    }
                    if model.profileNameReplacesExisting {
                        Label("A profile with this name exists; the run will replace it.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Mode", selection: $model.calibrate) {
                        Text("Profile only").tag(false)
                        Text("Calibrate, then profile").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(model.calibrate
                         ? "Calibrate changes the display: Argyll works out an adjustment that pushes it toward the white point and gamma below, then measures the result. Use it only for a display that has no Preset of its own for the white you want."
                         : "Profile only leaves the display exactly as it is and measures it. The profile tells colour-managed apps like Lightroom how this panel behaves so they show images correctly. Right choice when the display already has the white point you want, e.g. from its Apple Preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.calibrate {
                        Picker("White point", selection: $model.whitePointKelvin) {
                            Text("Native").tag(0)
                            Text("5000 K").tag(5000)
                            Text("5500 K").tag(5500)
                            Text("6500 K").tag(6500)
                        }
                        Picker("Gamma", selection: $model.gamma) {
                            Text("1.8").tag(1.8)
                            Text("2.2").tag(2.2)
                            Text("2.4").tag(2.4)
                        }
                    }
                    Picker("Patches", selection: $model.patchCount) {
                        Text("Quick · 48").tag(48)
                        Text("Standard · 175").tag(175)
                        Text("Thorough · 400").tag(400)
                    }
                    .pickerStyle(.segmented)
                    Picker("Patch window", selection: $model.patchVertical) {
                        Text("Top").tag(0.0)
                        Text("Centre").tag(0.5)
                        Text("Bottom").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                    Picker("Patch size", selection: $model.patchScale) {
                        Text("Normal").tag(1.0)
                        Text("Large").tag(2.0)
                        Text("Huge").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                    Text("Where the measuring window appears on the display. A large instrument on a tilted laptop screen wants it low and large so it can rest on the patch.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Quality", selection: $model.quality) {
                        Text("Low").tag(Character("l"))
                        Text("Medium").tag(Character("m"))
                        Text("High").tag(Character("h"))
                    }
                    Toggle("Install the profile when done", isOn: $model.installProfile)
                    Toggle("Reuse the instrument's last white calibration if still valid", isOn: $model.skipInstrumentCalibration)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Button("Compare profiles…") { model.openCompare() }
                    .disabled(model.displays.isEmpty)
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Start") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.instruments.isEmpty || model.displays.isEmpty || model.profileName.isEmpty)
            }
            .padding()
        }
    }

    private var footnote: String {
        model.calibrate
            ? "Calibration adjustments may not survive a display reconnect on this macOS."
            : "Nothing to prepare: leave the display on the Preset you normally use and press Start."
    }
}

// MARK: - Run

struct RunView: View {
    @EnvironmentObject var model: RunModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 20) {
            StageStrip()
                .padding(.top, 8)

            Spacer(minLength: 0)

            if let prompt = model.prompt {
                PromptCard(prompt: prompt)
            } else {
                ProgressPanel()
            }

            Spacer(minLength: 0)

            DisclosureGroup("Log", isExpanded: $showLog) {
                LogView()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        }
        .padding(24)
    }
}

struct StageStrip: View {
    @EnvironmentObject var model: RunModel

    var body: some View {
        HStack(spacing: 18) {
            ForEach(model.stages, id: \.self) { stage in
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: stage))
                        .foregroundStyle(color(for: stage))
                    Text(label(for: stage))
                        .font(.callout)
                        .foregroundStyle(model.stageStates[stage] == .pending ? .secondary : .primary)
                }
            }
        }
    }

    private func label(for stage: ProfilingSession.Stage) -> String {
        switch stage {
        case .targen: return "Chart"
        case .dispcal: return "Calibrate"
        case .dispread: return "Measure"
        case .colprof: return "Build"
        case .dispwin: return "Install"
        }
    }

    private func symbol(for stage: ProfilingSession.Stage) -> String {
        switch model.stageStates[stage] ?? .pending {
        case .pending: return "circle"
        case .running: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for stage: ProfilingSession.Stage) -> Color {
        switch model.stageStates[stage] ?? .pending {
        case .pending: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }
}

struct ProgressPanel: View {
    @EnvironmentObject var model: RunModel

    var body: some View {
        VStack(spacing: 14) {
            if let p = model.progress {
                ProgressView(value: Double(p.done), total: Double(p.total))
                Text("Measuring patch \(p.done) of \(p.total)")
                    .font(.title3)
            } else {
                ProgressView()
                Text(status)
                    .font(.title3)
            }
        }
        .frame(maxWidth: 380)
    }

    private var status: String {
        switch model.currentStage {
        case .targen: return "Generating the test chart…"
        case .dispcal: return "Calibrating…"
        case .dispread: return "Setting up the instrument…"
        case .colprof: return "Building the profile…"
        case .dispwin: return "Installing the profile…"
        case nil: return "Starting…"
        }
    }
}

struct PromptCard: View {
    @EnvironmentObject var model: RunModel
    let prompt: ArgyllPrompt

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(instructions)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Continue") { model.continueAfterPrompt() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }

    private var icon: String {
        switch prompt {
        case .placeOnWhiteTile: return "circle.lefthalf.filled"
        case .placeOnDisplay: return "display"
        case .other: return "hand.raised"
        }
    }

    private var title: String {
        switch prompt {
        case .placeOnWhiteTile: return "Calibrate the instrument"
        case .placeOnDisplay: return "Place it on the display"
        case .other: return "Argyll needs you"
        }
    }

    private var instructions: String {
        switch prompt {
        case .placeOnWhiteTile:
            return "Put the \(model.promptInstrumentName) on its white reference tile, then press Continue."
        case .placeOnDisplay:
            return "A patch window is open on \(model.selectedDisplayName). Put the \(model.promptInstrumentName) flat against it, then press Continue."
        case .other(let text):
            return text
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: RunModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(item.offset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .onChange(of: model.log.count) { count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    @EnvironmentObject var model: RunModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.green)
            Text(model.summary?.installed == true ? "Profile installed and active" : "Profile built")
                .font(.title2.weight(.semibold))

            if let s = model.summary {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Profile", s.profileURL.lastPathComponent)
                    if let l = s.luminance {
                        row("Luminance", String(format: "%.0f cd/m²", l))
                    }
                    if let c = s.whiteChromaticity, let k = s.correlatedColorTemperature {
                        row("White point", String(format: "x %.4f  y %.4f  (≈ %.0f K)", c.x, c.y, k))
                    }
                    if let a = s.avgError, let p = s.peakError {
                        row("Fit", String(format: "avg %.2f ΔE, peak %.2f ΔE", a, p))
                    }
                    if !s.installed {
                        row("Location", s.profileURL.deletingLastPathComponent().path)
                    }
                }
                .padding(.vertical, 8)

                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([s.profileURL])
                    }
                    Button("Open in ColorSync Utility") {
                        let app = URL(fileURLWithPath: "/System/Applications/Utilities/ColorSync Utility.app")
                        NSWorkspace.shared.open([s.profileURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }

            if model.summary?.installed == true {
                Text("Lightroom, Photoshop and other apps that manage colour themselves read the display profile when they start. Relaunch them to pick this one up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                Button("New run") { model.reset() }
                if model.summary?.installed == true {
                    Button("Compare with previous") { model.openCompare() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Compare

struct CompareView: View {
    @EnvironmentObject var model: RunModel
    @State private var dropTargeted = false
    @State private var showNumbers = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Comparing profiles on \(model.compareDisplayName)")
                .font(.title3.weight(.semibold))

            // One row: A + menu, switch, B + menu. The active letter is highlighted.
            HStack(spacing: 12) {
                profilePicker("A", selection: $model.compareA, url: model.compareA)
                Button {
                    model.toggleCompare()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 22)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.space, modifiers: [])
                .help("Switch the shown profile (space)")
                profilePicker("B", selection: $model.compareB, url: model.compareB)
            }
            Text("Showing \(model.activeProfile == model.compareA ? "A" : (model.activeProfile == model.compareB ? "B" : "neither"))")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack {
                if let image = model.renderedImage ?? model.referenceImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .id(model.activeProfile)
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.useReferenceImage(at: url)
                return true
            } isTargeted: { dropTargeted = $0 }

            HStack {
                Text("Drop a photo onto the image, or")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Choose…") { model.chooseReferenceImage() }.controlSize(.small)
                Button("Built-in patches") { model.referenceImage = TestImage.make() }.controlSize(.small)
                Spacer()
                Text("Converted through the active profile, as Lightroom does. Space switches, A and B select.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Numbers", isExpanded: $showNumbers) {
                NumbersView(a: model.compareA, b: model.compareB)
            }

            HStack {
                Button("Apple factory profile") {
                    model.activate(model.compareProfiles.first { $0.isFactory }?.url)
                }
                Spacer()
                Button("Done") { model.reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    /// Letter badge (highlighted when that profile is showing; tap to show it) plus its menu.
    private func profilePicker(_ label: String, selection: Binding<URL?>, url: URL?) -> some View {
        let active = model.activeProfile == url
        return HStack(spacing: 8) {
            Button {
                model.activate(url)
            } label: {
                Text(label)
                    .font(.headline)
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .frame(width: 24, height: 22)
                    .background(active ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(KeyEquivalent(Character(label.lowercased())), modifiers: [])
            .help("Show \(label) (key \(label))")
            Picker(selection: selection) {
                ForEach(model.compareProfiles) { p in
                    Text(RunModel.compactLabel(p)).tag(Optional(p.url))
                }
            } label: { EmptyView() }
            .labelsHidden()
            .help(model.profileName(for: selection.wrappedValue))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Grey ramp through A and B as device values, with tints flagged, plus white points.
struct NumbersView: View {
    let a: URL?
    let b: URL?

    var body: some View {
        let rampA = ProfileInspector.greyRamp(through: a)
        let rampB = ProfileInspector.greyRamp(through: b)
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
            GridRow {
                Text("sRGB grey").foregroundStyle(.secondary)
                Text("A → device R / G / B").foregroundStyle(.secondary)
                Text("B → device R / G / B").foregroundStyle(.secondary)
            }
            .font(.caption)
            ForEach(ProfileInspector.rampLevels, id: \.self) { level in
                GridRow {
                    Text("\(level) %")
                    cell(rampA[level])
                    cell(rampB[level])
                }
                .font(.system(.body, design: .monospaced))
            }
            GridRow {
                Text("white point").foregroundStyle(.secondary)
                Text(whiteText(a))
                Text(whiteText(b))
            }
            .font(.caption)
        }
        .padding(.top, 6)
        Text("A tint is flagged when a profile's channels differ by more than 2 for the same grey. Differences of one or two levels between A and B are normal for two measurements of one panel.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func cell(_ rgb: ProfileInspector.RGB?) -> some View {
        if let rgb {
            HStack(spacing: 6) {
                Text(rgb.text)
                if rgb.spread > 2 {
                    Text("tint").font(.caption2).foregroundStyle(.orange)
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func whiteText(_ url: URL?) -> String {
        guard let url, let w = ProfileInspector.whitePoint(of: url) else { return "—" }
        if w.isD50 { return "D50 (v4 profile, adapted)" }
        return String(format: "x %.4f  y %.4f  ≈ %.0f K", w.x, w.y, w.cct)
    }
}

// MARK: - Correction matrix

struct CorrectionView: View {
    @EnvironmentObject var model: RunModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Correction matrix for \(model.selectedInstrumentName) on \(model.selectedDisplayName)")
                .font(.title3.weight(.semibold))

            if !model.correctionStarted {
                Text("A colorimeter reads a display accurately only through a correction for that panel's backlight. The \(model.spectrometerName) measures four patches as the reference, the \(model.selectedInstrumentName) measures the same four, and Argyll computes a matrix that makes the colorimeter agree with the spectrophotometer on this display. From then on every run with the colorimeter uses it automatically.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Form {
                    Picker("Backlight type", selection: $model.displayTechnology) {
                        ForEach(RunModel.displayTechnologies, id: \.code) { t in
                            Text(t.name).tag(t.code)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 520, maxHeight: 90)
                Text("Put the \(model.selectedInstrumentName) on the display first; you will be asked to swap in the \(model.spectrometerName) halfway.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Back") { model.reset() }
                    Button("Start") { model.startCorrection() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 18) {
                    stage("Colorimeter", .colorimeter)
                    stage("Spectrophotometer", .spectrometer)
                    stage("Compute", .computing)
                }
                Spacer(minLength: 0)
                if let prompt = model.prompt {
                    PromptCard(prompt: prompt)
                } else {
                    VStack(spacing: 14) {
                        if let p = model.progress {
                            ProgressView(value: Double(p.done), total: Double(p.total))
                            Text("Measuring patch \(p.done) of \(p.total) with the \(model.promptInstrumentName)").font(.title3)
                        } else {
                            ProgressView()
                            Text(model.correctionStep == .computing ? "Computing the matrix…" : "Setting up…").font(.title3)
                        }
                    }
                    .frame(maxWidth: 380)
                }
                Spacer(minLength: 0)
                DisclosureGroup("Log", isExpanded: $showLog) { LogView() }
                HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancelCorrection() } }
            }
        }
        .padding(24)
    }

    private func stage(_ label: String, _ step: CorrectionSession.Step) -> some View {
        let order: [CorrectionSession.Step] = [.colorimeter, .spectrometer, .computing]
        let current = model.correctionStep.flatMap { order.firstIndex(of: $0) } ?? -1
        let mine = order.firstIndex(of: step)!
        let symbol = mine < current ? "checkmark.circle.fill" : (mine == current ? "circle.dotted" : "circle")
        let color: Color = mine < current ? .green : (mine == current ? .accentColor : .secondary)
        return HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(label).font(.callout).foregroundStyle(mine <= current ? .primary : .secondary)
        }
    }
}

struct CorrectionDoneView: View {
    @EnvironmentObject var model: RunModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.green)
            Text("Matrix saved").font(.title2.weight(.semibold))
            if let r = model.correctionResult {
                if let avg = r.fitAverage, let max = r.fitMax {
                    Text(String(format: "Fit error avg %.2f ΔE, max %.2f ΔE across the reference patches", avg, max))
                }
                Text(r.url.lastPathComponent).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("Every run with the \(model.selectedInstrumentName) on \(model.selectedDisplayName) will use it from now on. Profile the display again to benefit.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Done") { model.reset() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
    }
}

struct FailedView: View {
    @EnvironmentObject var model: RunModel
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.red)
            Text("The run stopped")
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            LogView()
            Button("Back") { model.reset() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}
