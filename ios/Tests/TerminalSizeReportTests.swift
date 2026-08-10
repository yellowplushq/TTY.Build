import Foundation
import GhosttyTerminal
import Testing
@testable import TTYBuild

struct TerminalSizeReportTests {
    @Test
    func extractsAppliedSizeReportAndDerivesCellMetrics() {
        let (passthrough, reports) = TerminalSizeReport.extract(
            from: Data("\u{1b}[48;37;48;2010;1206t".utf8)
        )

        #expect(passthrough.isEmpty)
        #expect(reports.map(\.viewport) == [
            InMemoryTerminalViewport(
                columns: 48,
                rows: 37,
                widthPixels: 1206,
                heightPixels: 2010,
                cellWidthPixels: 25,
                cellHeightPixels: 54
            ),
        ])
    }

    @Test
    func passesSurroundingHostInputThroughUnchanged() {
        let (passthrough, reports) = TerminalSizeReport.extract(
            from: Data("abc\u{1b}[48;21;48;1134;1206tdef".utf8)
        )

        #expect(String(decoding: passthrough, as: UTF8.self) == "abcdef")
        #expect(reports.count == 1)
        #expect(reports.first?.rows == 21)
        #expect(reports.first?.columns == 48)
    }

    @Test
    func leavesOtherEscapeSequencesUntouched() {
        let inputs = [
            "\u{1b}[A",                   // arrow key
            "\u{1b}[48;1t",               // too few fields
            "\u{1b}[48;1;2;3;4;5t",       // too many fields
            "\u{1b}[8;37;48t",            // XTWINOPS, not mode 2048
            "\u{1b}[48;37;48;2010;1206x", // wrong terminator
            "\u{1b}",                     // bare ESC at end of chunk
        ]

        for input in inputs {
            let (passthrough, reports) = TerminalSizeReport.extract(
                from: Data(input.utf8)
            )
            #expect(String(decoding: passthrough, as: UTF8.self) == input)
            #expect(reports.isEmpty)
        }
    }

    @Test
    func extractsConsecutiveReports() {
        let (passthrough, reports) = TerminalSizeReport.extract(
            from: Data("\u{1b}[48;21;48;1134;1206t\u{1b}[48;37;48;2010;1206t".utf8)
        )

        #expect(passthrough.isEmpty)
        #expect(reports.map(\.rows) == [21, 37])
    }
}
