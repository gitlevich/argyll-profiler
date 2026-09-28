import Foundation
import ArgyllKit

// argyllkit-cli list
// argyllkit-cli profile --display N --name NAME [--port N] [--patches N] [--quality l|m|h]
//                       [--web PORT] [--calibrate] [--no-install] [--dir PATH] [--control PATH]
//
// --control PATH: instead of waiting for Return at a prompt, wait until PATH exists,
// then delete it and continue. Lets the run be driven from another process.

setlinebuf(stdout)

func usage() -> Never {
    print("usage: argyllkit-cli list | profile --display N --name NAME [--port N] [--patches N] [--quality l|m|h] [--web PORT] [--calibrate] [--no-install] [--dir PATH] [--control PATH]")
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
        let control = value("--control", in: args)
        let dir = URL(fileURLWithPath: value("--dir", in: args) ?? FileManager.default.currentDirectoryPath)

        let session = ProfilingSession(options: options, directory: dir)
        let run = Task { try await session.run() }
        for await (stage, event) in session.events {
            switch event {
            case .line(let line):
                print("[\(stage)] \(line)")
            case .progress(let done, let total):
                print("[\(stage)] PROGRESS \(done)/\(total)")
            case .prompt(let prompt):
                print("[\(stage)] PROMPT \(prompt)")
                await waitForGo(control)
                await session.answerPrompt()
                print("[\(stage)] answered")
            case .error(let message):
                print("[\(stage)] ERROR \(message)")
            case .exited(let code):
                print("[\(stage)] EXIT \(code)")
            }
        }
        let url = try await run.value
        print("DONE \(url.path)")

    default:
        usage()
    }
} catch {
    print("FAILED: \(error)")
    exit(1)
}
