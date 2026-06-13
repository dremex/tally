import Testing
@testable import Tally

@Suite("QualityScorer")
struct QualityScorerTests {
    @Test("Perfect connection scores 100")
    func perfect() {
        let s = QualityScorer.score(latencyMs: 0, jitterMs: 0, lossPct: 0)
        #expect(s == 100)
        #expect(QualityScorer.level(for: s) == .excellent)
    }

    @Test("Awful connection scores 0")
    func awful() {
        let s = QualityScorer.score(latencyMs: 500, jitterMs: 200, lossPct: 50)
        #expect(s == 0)
        #expect(QualityScorer.level(for: s) == .poor)
    }

    @Test("Score is clamped to 0...100")
    func clamped() {
        let low = QualityScorer.score(latencyMs: 9999, jitterMs: 9999, lossPct: 100)
        let high = QualityScorer.score(latencyMs: -50, jitterMs: -50, lossPct: -50)
        #expect(low >= 0 && low <= 100)
        #expect(high >= 0 && high <= 100)
    }

    @Test("Higher latency lowers the score, all else equal")
    func latencyMonotonic() {
        let good = QualityScorer.score(latencyMs: 10, jitterMs: 0, lossPct: 0)
        let worse = QualityScorer.score(latencyMs: 120, jitterMs: 0, lossPct: 0)
        #expect(worse < good)
    }

    @Test("Packet loss is weighted heavily")
    func lossHurts() {
        let clean = QualityScorer.score(latencyMs: 20, jitterMs: 5, lossPct: 0)
        let lossy = QualityScorer.score(latencyMs: 20, jitterMs: 5, lossPct: 10)
        #expect(lossy < clean)
        #expect(clean - lossy >= 25) // 30% weight × full loss component swing
    }

    @Test("Level thresholds", arguments: [
        (95.0, QualityLevel.excellent),
        (85.0, .excellent),
        (84.0, .good),
        (65.0, .good),
        (64.0, .fair),
        (40.0, .fair),
        (39.0, .poor),
        (0.0, .poor),
    ])
    func levels(score: Double, expected: QualityLevel) {
        #expect(QualityScorer.level(for: score) == expected)
    }
}
