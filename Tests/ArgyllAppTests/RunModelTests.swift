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
