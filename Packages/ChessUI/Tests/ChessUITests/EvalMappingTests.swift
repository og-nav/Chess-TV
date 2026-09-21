import Testing
@testable import ChessUI

@Test func evenPositionIsHalfTheBar() {
    #expect(EvalMapping.whiteShare(centipawns: 0) == 0.5)
}

@Test func centipawnsMapThroughTheLichessCurve() {
    #expect(abs(EvalMapping.whiteShare(centipawns: 400) - 0.909090909) < 1e-6)
    #expect(abs(EvalMapping.whiteShare(centipawns: -400) - 0.090909091) < 1e-6)
    #expect(abs(EvalMapping.whiteShare(centipawns: 100) - 0.640065109) < 1e-6)
    // Symmetry around 0.5, and monotonic in White's favour.
    for centipawns in stride(from: -2000, through: 2000, by: 137) {
        let share = EvalMapping.whiteShare(centipawns: centipawns)
        #expect(share > 0 && share < 1)
        #expect(abs(share + EvalMapping.whiteShare(centipawns: -centipawns) - 1) < 1e-9)
    }
    #expect(EvalMapping.whiteShare(centipawns: 50) < EvalMapping.whiteShare(centipawns: 51))
    #expect(EvalMapping.whiteShare(centipawns: 10_000) > 0.999)
}

@Test func mateClampsTheBar() {
    #expect(EvalMapping.whiteShare(mateIn: 1) == 1.0)
    #expect(EvalMapping.whiteShare(mateIn: 7) == 1.0)
    #expect(EvalMapping.whiteShare(mateIn: -1) == 0.0)
    #expect(EvalMapping.whiteShare(mateIn: -7) == 0.0)
    #expect(EvalMapping.whiteShare(mateIn: 0) == 0.5)
}

@Test func centipawnDisplayStrings() {
    #expect(EvalMapping.displayString(centipawns: 40) == "+0.4")
    #expect(EvalMapping.displayString(centipawns: 0) == "+0.0")
    #expect(EvalMapping.displayString(centipawns: -120) == "\u{2212}1.2")
    #expect(EvalMapping.displayString(centipawns: 1234) == "+12.3")
    #expect(EvalMapping.displayString(centipawns: -250) == "\u{2212}2.5")
    // A real minus sign, never a hyphen.
    #expect(!EvalMapping.displayString(centipawns: -120).contains("-"))
}

@Test func mateDisplayStrings() {
    #expect(EvalMapping.displayString(mateIn: 3) == "M3")
    #expect(EvalMapping.displayString(mateIn: -2) == "\u{2212}M2")
    #expect(EvalMapping.displayString(mateIn: 0) == "M0")
}
