import XCTest
@testable import ArgyllKit

/// The fixtures are verbatim from a real `dispread -v -H -d2 -c1` run against an
/// X-Rite i1 Pro 2 on a Studio Display (2026-09-28). Prompts end in ":" with no
/// newline, and their wording spans several lines.
///
/// Each fixture is one "phase": everything Argyll prints before it blocks on a key.
/// Output from the next phase can only arrive after the key is sent, so tests feed
/// phases separately and never merge across that boundary.
final class ArgyllOutputParserTests: XCTestCase {

    static let setup = """
        Number of patches = 48
        Setting up the instrument
        Instrument Type:   X-Rite i1 Pro 2
        Serial Number:     1062057
        Total lamp usage:                 948.371216
        dispread: Warning - new_dispwin: Frame buffer depth 8 doesn't match VideoLUT 10

        Place the instrument on its reflective white reference S/N 1062057,
         and then hit any key to continue,
         or hit Esc or Q to abort:\u{20}
        """

    static let afterTile = """

        Calibration complete

        Place instrument on test window.
        Hit Esc or Q to give up, any other key to continue:
        """

    static let measuring = """

        Measured display update delay of 43 msec, using delay of 157 msec & 0 msec inst reaction

        patch 1 of 48
        patch 2 of 48
        patch 48 of 48
        Instrument Type:   X-Rite i1 Pro 2

        """

    private func events(from phases: [String], chunkSize: Int) -> [ArgyllEvent] {
        var parser = ArgyllOutputParser()
        var out: [ArgyllEvent] = []
        for phase in phases {
            let bytes = Array(phase.utf8)
            var i = 0
            while i < bytes.count {
                let end = min(i + chunkSize, bytes.count)
                out += parser.feed(Data(bytes[i..<end]))
                i = end
            }
        }
        out += parser.flush()
        return out
    }

    private func prompts(_ events: [ArgyllEvent]) -> [ArgyllPrompt] {
        events.compactMap { if case .prompt(let p) = $0 { return p } else { return nil } }
    }

    private func progress(_ events: [ArgyllEvent]) -> [(Int, Int)] {
        events.compactMap { if case .progress(let d, let t) = $0 { return (d, t) } else { return nil } }
    }

    func testWhiteTilePromptSpansThreeLines() {
        let e = events(from: [Self.setup], chunkSize: 4096)
        XCTAssertEqual(prompts(e), [.placeOnWhiteTile])
    }

    func testDisplayPromptUsesPrecedingLine() {
        let e = events(from: [Self.afterTile], chunkSize: 4096)
        XCTAssertEqual(prompts(e), [.placeOnDisplay])
    }

    func testPromptsAreStableAcrossChunkBoundaries() {
        for size in [1, 3, 7, 16, 64, 4096] {
            let e = events(from: [Self.setup, Self.afterTile, Self.measuring], chunkSize: size)
            XCTAssertEqual(prompts(e), [.placeOnWhiteTile, .placeOnDisplay], "chunk size \(size)")
            XCTAssertEqual(progress(e).map { $0.0 }, [1, 2, 48], "chunk size \(size)")
        }
    }

    func testProgressLinesAndColonTailsAreNotPrompts() {
        let e = events(from: [Self.measuring], chunkSize: 5)
        XCTAssertEqual(progress(e).map { $0.0 }, [1, 2, 48])
        XCTAssertEqual(progress(e).first?.1, 48)
        XCTAssertTrue(prompts(e).isEmpty)
    }

    func testInstrumentTypeTailAtChunkBoundaryIsNotAPrompt() {
        // Chunk ends right after "Instrument Type:" — looks like a prompt terminator but
        // no key phrase is in context.
        var parser = ArgyllOutputParser()
        var e = parser.feed(Data("Setting up the instrument\nInstrument Type:".utf8))
        e += parser.feed(Data("   X-Rite i1 Pro 2\n".utf8))
        XCTAssertTrue(prompts(e).isEmpty)
    }

    func testPromptFollowedByNewlineInSameChunkIsNotAPrompt() {
        // If the newline that follows the terminator is already there, Argyll is not
        // blocked (the key was answered some other way), so no prompt must be raised.
        let e = events(from: [Self.setup + "\n"], chunkSize: 4096)
        XCTAssertTrue(prompts(e).isEmpty)
    }

    func testErrorLine() {
        let e = events(from: ["dispread: Error - Instrument Access Failed\n"], chunkSize: 4096)
        let errors = e.compactMap { if case .error(let m) = $0 { return m } else { return nil } }
        XCTAssertEqual(errors, ["Instrument Access Failed"])
    }

    func testUnknownPromptFallsBackToOther() {
        let e = events(from: ["Something unexpected happened,\nhit any key to retry:"], chunkSize: 4096)
        guard case .other(let text)? = prompts(e).first else {
            return XCTFail("expected .other, got \(prompts(e))")
        }
        XCTAssertTrue(text.contains("hit any key to retry"))
    }
}
