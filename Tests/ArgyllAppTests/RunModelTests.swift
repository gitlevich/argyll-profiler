import XCTest
import ArgyllKit
@testable import ArgyllApp

@MainActor
final class RunModelTests: XCTestCase {

    /// BUGS.md #2. The run closure returns before its last events have been handled
    /// (yields are synchronous, the consumer task has not been scheduled yet), so the
    /// summary must still contain everything harvested from colprof.
    func testSummaryIsCompleteWhenRunReturnsBeforeEventsDrain() async throws {
        let model = RunModel()
        let url = URL(fileURLWithPath: "/tmp/x/AppTest.icc")

        var continuation: AsyncStream<(ProfilingSession.Stage, ArgyllEvent)>.Continuation!
        let events = AsyncStream<(ProfilingSession.Stage, ArgyllEvent)> { continuation = $0 }
        let cont = continuation!

        model.attach(stages: [.colprof], profileURL: url, installed: false, events: events) {
            cont.yield((.colprof, .line("Display Luminance = 270.802274")))
            cont.yield((.colprof, .line("White point XYZ = 0.950705 1.000000 1.177667")))
            cont.yield((.colprof, .line("Profile check complete, peak err = 1.343002, avg err = 0.287389, RMS = 0.401743")))
            cont.yield((.colprof, .exited(code: 0)))
            cont.finish()
            return url
        }

        for _ in 0..<200 where model.phase != .finished {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.stageStates[.colprof], .done)
        XCTAssertEqual(model.summary?.luminance ?? 0, 270.8, accuracy: 0.1)
        XCTAssertEqual(model.summary?.avgError ?? 0, 0.287, accuracy: 0.001)
        XCTAssertEqual(model.summary?.peakError ?? 0, 1.343, accuracy: 0.001)
        XCTAssertEqual(model.summary?.correlatedColorTemperature ?? 0, 7000, accuracy: 700)
    }

    func testInstrumentAndDisplayNamesAreCleanedUp() {
        XCTAssertEqual(RunModel.instrumentName("usb1: (X-Rite i1 Pro 2)"), "i1 Pro 2")
        XCTAssertEqual(RunModel.instrumentName("/dev/cu.BathysMG"), "/dev/cu.BathysMG")
        XCTAssertEqual(RunModel.shortName("Studio Display, at -621, -1800, width 3200, height 1800"), "Studio Display")
    }

    func testSuggestedProfileNameCarriesProvenance() {
        let model = RunModel()
        model.displays = [Argyll.Display(index: 2, name: "Studio Display, at -621, -1800, width 3200, height 1800")]
        model.instruments = [Argyll.Instrument(port: 1, name: "usb1: (X-Rite i1 Pro 2)")]
        model.displayIndex = 2
        model.instrumentPort = 1
        let date = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 in UTC; formatter uses local time
        let name = model.suggestedProfileName(at: date)
        XCTAssertTrue(name.hasPrefix("StudioDisplay_i1Pro2_ArgyllProfiler_2026-09-2"), name)
        XCTAssertFalse(name.contains(" "))
        // The form follows the selection until the user types their own name.
        XCTAssertEqual(model.profileName, model.suggestedProfileName())
        model.profileName = "MyOwnName"
        model.profileNameEdited(model.profileName)
        model.displayIndex = 2
        XCTAssertEqual(model.profileName, "MyOwnName")
        let description = model.profileDescription(at: date)
        XCTAssertTrue(description.contains("Studio Display - i1 Pro 2 spectrophotometer - Argyll Profiler"), description)
        XCTAssertTrue(description.contains("profile only, 175 patches"), description)
    }

    /// BUGS.md #3. colprof writes the ICC v2 description tag as 7-bit ASCII, so any
    /// non-ASCII separator comes out as "?" in System Settings and in the app.
    func testProfileDescriptionIsPlainASCII() {
        let model = RunModel()
        model.displays = [Argyll.Display(index: 2, name: "Studio Display, at -621, -1800, width 3200, height 1800")]
        model.instruments = [Argyll.Instrument(port: 1, name: "hid1: (X-Rite i1 DisplayPro, ColorMunki Display)")]
        model.displayIndex = 2
        model.instrumentPort = 1
        let description = model.profileDescription()
        XCTAssertTrue(description.allSatisfy { $0.isASCII }, description)
        XCTAssertTrue(description.hasPrefix("Studio Display - i1 DisplayPro family colorimeter - Argyll Profiler"), description)
        XCTAssertEqual(RunModel.instrumentName("hid1: (X-Rite i1 DisplayPro, ColorMunki Display)"), "i1 DisplayPro family")
    }

    func testInstrumentKindsAndNicknames() {
        XCTAssertEqual(RunModel.instrumentKind("usb1: (X-Rite i1 Pro 2)"), .spectrophotometer)
        XCTAssertEqual(RunModel.instrumentKind("hid1: (X-Rite i1 DisplayPro, ColorMunki Display)"), .colorimeter)
        XCTAssertEqual(RunModel.instrumentKind("/dev/cu.Bluetooth-Incoming-Port"), .unknown)
        let model = RunModel()
        let hl = Argyll.Instrument(port: 1, name: "hid1: (X-Rite i1 DisplayPro, ColorMunki Display)")
        model.instruments = [hl]
        model.instrumentPort = 1
        XCTAssertEqual(model.instrumentLabel(hl), "Colorimeter: i1 DisplayPro family")
        model.setNickname("Calibrite Display Plus HL")
        XCTAssertEqual(model.instrumentLabel(hl), "Colorimeter: Calibrite Display Plus HL")
        XCTAssertTrue(model.profileDescription().contains("Calibrite Display Plus HL colorimeter"), model.profileDescription())
        XCTAssertTrue(model.suggestedProfileName().contains("CalibriteDisplayPlusHL"), model.suggestedProfileName())
        model.setNickname("")
        XCTAssertEqual(model.instrumentLabel(hl), "Colorimeter: i1 DisplayPro family")
    }

    func testFailedRunStillDrainsEvents() async throws {
        let model = RunModel()
        var continuation: AsyncStream<(ProfilingSession.Stage, ArgyllEvent)>.Continuation!
        let events = AsyncStream<(ProfilingSession.Stage, ArgyllEvent)> { continuation = $0 }
        let cont = continuation!
        struct Boom: Error {}

        model.attach(stages: [.dispread], profileURL: URL(fileURLWithPath: "/tmp/x.icc"), installed: true, events: events) {
            cont.yield((.dispread, .error("Instrument Access Failed")))
            cont.yield((.dispread, .exited(code: 1)))
            cont.finish()
            throw Boom()
        }

        for _ in 0..<200 where model.phase == .running {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .failed = model.phase else { return XCTFail("expected .failed, got \(model.phase)") }
        XCTAssertEqual(model.stageStates[.dispread], .failed)
        XCTAssertTrue(model.log.contains { $0.contains("Instrument Access Failed") })
    }
}
