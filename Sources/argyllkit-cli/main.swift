import Foundation
import ArgyllKit

// argyllkit-cli list
// argyllkit-cli profile --display N --name NAME [--port N] [--patches N] [--quality l|m|h]
//                       [--web PORT] [--calibrate] [--no-install] [--dir PATH] [--control PATH]
// argyllkit-cli run [--control PATH] -- TOOL ARGS…      (any Argyll tool, same prompt handling)
//
// --control PATH: instead of waiting for Return at a prompt, wait until PATH exists,
// then delete it and continue. Lets the run be driven from another process.

setlinebuf(stdout)

func usage() -> Never {
    print("usage: argyllkit-cli list | profile --display N --name NAME [--port N] [--patches N] [--quality l|m|h] [--web PORT] [--calibrate] [--no-install] [--dir PATH] [--control PATH] | run [--control PATH] -- TOOL ARGS…")
    exit(2)
}

func value(_ flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func waitForGo(_ control: String?) async {
    guard let control else {
        print("press Return to continue")
        _ = readLine()
        return
    }
    print("waiting for \(control)")
    while !FileManager.default.fileExists(atPath: control) {
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    try? FileManager.default.removeItem(atPath: control)
}

func report(_ stage: String, _ event: ArgyllEvent, control: String?, answer: () async -> Void) async {
    switch event {
    case .line(let line):
        print("[\(stage)] \(line)")
    case .progress(let done, let total):
        print("[\(stage)] PROGRESS \(done)/\(total)")
    case .prompt(let prompt):
        print("[\(stage)] PROMPT \(prompt)")
        await waitForGo(control)
        await answer()
        print("[\(stage)] answered")
    case .error(let message):
        print("[\(stage)] ERROR \(message)")
    case .exited(let code):
        print("[\(stage)] EXIT \(code)")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

do {
    switch command {
    case "list":
        print("displays:")
        for d in try await Argyll.displays() { print("  \(d.index) = \(d.name)") }
        print("instruments:")
        for i in try await Argyll.instruments() { print("  \(i.port) = \(i.name)") }

    case "profile":
        guard let display = value("--display", in: args).flatMap(Int.init),
              let name = value("--name", in: args) else { usage() }
        var options = ProfilingOptions(displayIndex: display,
                                       instrumentPort: value("--port", in: args).flatMap(Int.init) ?? 1,
                                       profileName: name)
        if let p = value("--patches", in: args).flatMap(Int.init) { options.patchCount = p }
        if let q = value("--quality", in: args)?.first { options.quality = q }
        if let w = value("--web", in: args).flatMap(Int.init) { options.patchServerPort = w }
        if args.contains("--calibrate") { options.calibration = ProfilingOptions.Calibration() }
        if args.contains("--no-install") { options.installProfile = false }
        if args.contains("--skip-cal") { options.skipInstrumentCalibrationIfPossible = true }
        let control = value("--control", in: args)
        let dir = URL(fileURLWithPath: value("--dir", in: args) ?? FileManager.default.currentDirectoryPath)

        let session = ProfilingSession(options: options, directory: dir)
        let run = Task { try await session.run() }
        for await (stage, event) in session.events {
            await report(stage.rawValue, event, control: control) { await session.answerPrompt() }
        }
        let url = try await run.value
        print("DONE \(url.path)")

    case "run":
        // With --keys PATH the tool is driven by a key file instead of prompt detection:
        // whenever PATH appears its contents are sent as keystrokes (empty file = Return)
        // and it is deleted. Needed for menu-driven tools such as ccxxmake.
        guard let sep = args.firstIndex(of: "--"), sep + 1 < args.count else { usage() }
        let control = value("--control", in: Array(args[..<sep]))
        let keyFile = value("--keys", in: Array(args[..<sep]))
        let tool = args[sep + 1]
        let toolArgs = Array(args[(sep + 2)...])
        let runner = try ArgyllRunner(tool: tool, arguments: toolArgs,
                                      workingDirectory: FileManager.default.currentDirectoryPath)
        if let keyFile {
            Task {
                while true {
                    if let data = FileManager.default.contents(atPath: keyFile) {
                        try? FileManager.default.removeItem(atPath: keyFile)
                        let keys = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                        print("[\(tool)] SEND \(keys.isEmpty ? "<return>" : keys)")
                        runner.send(keys.isEmpty ? "\r" : keys)
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        for await event in runner.events {
            if keyFile != nil, case .prompt(let p) = event { print("[\(tool)] PROMPT \(p)"); continue }
            await report(tool, event, control: control) { runner.answerPrompt() }
        }

    case "profiles":
        // argyllkit-cli profiles --display N        list assignable profiles, mark the active one
        // argyllkit-cli profiles --display N --use PATH|factory   assign one
        guard let display = value("--display", in: args).flatMap(Int.init) else { usage() }
        let displays = try await Argyll.displays()
        guard let entry = displays.first(where: { $0.index == display }),
              let id = DisplayProfiles.displayID(forArgyllName: entry.name) else {
            print("display \(display) not found"); exit(1)
        }
        if let use = value("--use", in: args) {
            let ok = DisplayProfiles.setProfile(use == "factory" ? nil : URL(fileURLWithPath: use), for: id)
            print(ok ? "assigned" : "failed")
        }
        let current = DisplayProfiles.currentProfileURL(for: id)
        for p in DisplayProfiles.availableProfiles(for: id) {
            print("\(p.url == current ? "*" : " ") \(p.isFactory ? "[factory] " : "")\(p.name)  —  \(p.url.path)")
        }

    case "correct":
        // argyllkit-cli correct --display N --colorimeter PORT --spectrometer PORT [--tech u] [--control PATH] OUT.ccmx
        guard let display = value("--display", in: args).flatMap(Int.init),
              let col = value("--colorimeter", in: args).flatMap(Int.init),
              let spec = value("--spectrometer", in: args).flatMap(Int.init),
              let out = args.last, out.hasSuffix(".ccmx") else { usage() }
        let control = value("--control", in: args)
        var options = CorrectionOptions(displayIndex: display, colorimeterPort: col, spectrometerPort: spec,
                                        displayName: "display \(display)", descriptor: "argyllkit-cli correction",
                                        outputURL: URL(fileURLWithPath: out))
        options.displayTechnology = value("--tech", in: args) ?? "u"
        let session = CorrectionSession(options: options)
        let run = Task { try await session.run() }
        for await event in session.events {
            switch event {
            case .line(let l): print("[ccxxmake] \(l)")
            case .step(let s): print("STEP \(s.rawValue)")
            case .progress(let d, let t): print("PROGRESS \(d)/\(t)")
            case .prompt(let p):
                print("PROMPT \(p)")
                await waitForGo(control)
                await session.answerPrompt()
                print("answered")
            case .exited(let c): print("EXIT \(c)")
            }
        }
        let result = try await run.value
        print("DONE \(result.url.path) avg=\(result.fitAverage ?? -1) max=\(result.fitMax ?? -1)")


    default:
        usage()
    }
} catch {
    print("FAILED: \(error)")
    exit(1)
}
