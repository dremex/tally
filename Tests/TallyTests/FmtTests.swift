import Testing
@testable import Tally

@Suite("Fmt")
struct FmtTests {
    @Test("Bytes under 1 KB show as whole B")
    func smallBytes() {
        #expect(Fmt.bytes(0 as Double) == "0 B")
        #expect(Fmt.bytes(512 as Double) == "512 B")
        #expect(Fmt.bytes(1023 as Double) == "1023 B")
    }

    @Test("Unit boundaries roll over at 1024")
    func boundaries() {
        let kb = 1024.0
        #expect(Fmt.bytes(kb) == "1.0 KB")
        #expect(Fmt.bytes(kb * kb) == "1.0 MB")
        #expect(Fmt.bytes(kb * kb * kb) == "1.0 GB")
    }

    @Test("One decimal under 100, no decimal at/above 100")
    func decimalRule() {
        #expect(Fmt.bytes(Double(1024 * 1024) * 2.1) == "2.1 MB")
        #expect(Fmt.bytes(Double(1024 * 1024) * 120) == "120 MB")
        #expect(Fmt.bytes(Double(1024 * 1024) * 99.9) == "99.9 MB")
    }

    @Test("Rate appends /s")
    func rate() {
        #expect(Fmt.rate(1024) == "1.0 KB/s")
        #expect(Fmt.rate(0) == "0 B/s")
    }

    @Test("Compact rate for the menu bar")
    func compact() {
        #expect(Fmt.compactRate(0) == "0")
        #expect(Fmt.compactRate(500) == "500")
        #expect(Fmt.compactRate(1024) == "1K")
        #expect(Fmt.compactRate(1024 * 1024) == "1.0M")
        #expect(Fmt.compactRate(Double(1024 * 1024) * 2.1) == "2.1M")
    }

    @Test("Int64 overload matches Double overload")
    func int64Overload() {
        #expect(Fmt.bytes(Int64(2048)) == Fmt.bytes(2048.0))
    }
}
