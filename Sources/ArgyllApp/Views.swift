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
            case .failed(let message): FailedView(message: message)
            }
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 700, idealHeight: 760)
        .task { await model.discoverIfNeeded() }
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var model: RunModel
    @State private var showNickname = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Hardware") {
                    Picker("Display", selection: $model.displayIndex) {
                        ForEach(model.displays, id: \.index) { d in
                            Text(RunModel.shortName(d.name)).tag(d.index)
                        }
                    }
                    HStack {
                        Picker("Instrument", selection: $model.instrumentPort) {
                            ForEach(model.instruments, id: \.port) { i in
                                Text(model.instrumentLabel(i)).tag(i.port)
                            }
                        }
                        Button("Name…") { showNickname = true }
                            .disabled(model.selectedInstrument == nil)
                            .popover(isPresented: $showNickname) {
                                NicknameEditor(initial: model.selectedInstrumentName) { model.setNickname($0); showNickname = false }
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
                    TextField("Profile name", text: $model.profileName)
                        .onChange(of: model.profileName) { model.profileNameEdited($0) }
                    Picker("Mode", selection: $model.calibrate) {
                        Text("Profile only").tag(false)
                        Text("Calibrate, then profile").tag(true)
                    }
                    .pickerStyle(.segmented)
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
            ? "Calibration writes gamma-table curves into the profile."
            : "The display is measured as it is. Set it to its Apple default profile first."
    }
}

struct NicknameEditor: View {
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is this instrument called?").font(.headline)
            Text("Argyll can't tell the i1 DisplayPro family apart; the name you give is used in the app and in the profile's provenance.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 300)
            TextField("e.g. Calibrite Display Plus HL", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(text) }
            HStack {
                Spacer()
                Button("Use") { commit(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { text = initial }
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
            return "Put the \(model.selectedInstrumentName) on its white reference tile, then press Continue."
        case .placeOnDisplay:
            return "A patch window is open on \(model.selectedDisplayName). Put the \(model.selectedInstrumentName) flat against it, then press Continue."
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

    var body: some View {
        VStack(spacing: 14) {
            Text("Comparing profiles on \(model.compareDisplayName)")
                .font(.title3.weight(.semibold))

            HStack(spacing: 16) {
                slot("A", selection: $model.compareA).frame(maxWidth: .infinity)
                slot("B", selection: $model.compareB).frame(maxWidth: .infinity)
            }

            ZStack {
                if let image = model.referenceImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
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
            }

            HStack(alignment: .top, spacing: 12) {
                sideButton("A", url: model.compareA)
                Button {
                    model.toggleCompare()
                } label: {
                    Label("Switch", systemImage: "arrow.left.arrow.right")
                }
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                .padding(.top, 2)
                sideButton("B", url: model.compareB)
            }

            Text("Space bar switches, A and B keys select. Whichever is active stays when you leave.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

    private func slot(_ label: String, selection: Binding<URL?>) -> some View {
        Picker(label, selection: selection) {
            ForEach(model.compareProfiles) { p in
                Text(p.isFactory ? "\(p.name) (Apple factory)" : p.name)
                    .tag(Optional(p.url))
            }
        }
    }

    private func sideButton(_ label: String, url: URL?) -> some View {
        let active = model.activeProfile == url
        return VStack(spacing: 6) {
            Button {
                model.activate(url)
            } label: {
                HStack(spacing: 6) {
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    Text(label).font(.title3.weight(.bold))
                }
                .frame(width: 200)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(active ? Color.accentColor : Color.secondary)
            .keyboardShortcut(KeyEquivalent(Character(label.lowercased())), modifiers: [])
            Text(url?.deletingPathExtension().lastPathComponent ?? "—")
                .font(.caption)
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 220)
                .help(model.profileName(for: url))
        }
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
