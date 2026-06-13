import Testing
@testable import Tally

@Suite("NettopParser")
struct NettopParserTests {
    /// Real-shaped nettop -J bytes_in,bytes_out output: a header line, then `name.pid,rx,tx,` rows.
    let sample = """
    ,bytes_in,bytes_out,
    launchd.1,12142095,0,
    Spotify.4823,77633,1696,
    Spotify Helper.4900,27542,30093,
    mDNSResponder.281,72061,900,
    """

    @Test("Parses process rows, skips the header")
    func basic() {
        let r = NettopParser.parse(sample)
        #expect(r["launchd"] == NettopParser.Bytes(rx: 12_142_095, tx: 0))
        #expect(r["Spotify"] == NettopParser.Bytes(rx: 77633, tx: 1696))
        #expect(r["mDNSResponder"] == NettopParser.Bytes(rx: 72061, tx: 900))
        #expect(r["bytes_in"] == nil) // header not captured
    }

    @Test("Strips the trailing .pid and keeps names with spaces/dots")
    func nameParsing() {
        let r = NettopParser.parse(sample)
        #expect(r["Spotify Helper"] == NettopParser.Bytes(rx: 27542, tx: 30093))
        #expect(r["Spotify Helper.4900"] == nil)
    }

    @Test("Sums multiple PIDs of the same process name")
    func sumsByName() {
        let multi = """
        ,bytes_in,bytes_out,
        Google Chrome H.100,100,10,
        Google Chrome H.200,200,20,
        Google Chrome H.300,300,30,
        """
        let r = NettopParser.parse(multi)
        #expect(r["Google Chrome H"] == NettopParser.Bytes(rx: 600, tx: 60))
    }

    @Test("Ignores malformed / short / non-numeric rows")
    func malformed() {
        let junk = """
        ,bytes_in,bytes_out,
        broken row with no commas
        OnlyOne.5
        BadNums.6,abc,def,
        Good.7,5,7,
        """
        let r = NettopParser.parse(junk)
        #expect(r.count == 1)
        #expect(r["Good"] == NettopParser.Bytes(rx: 5, tx: 7))
    }

    @Test("Empty input yields no rows")
    func empty() {
        #expect(NettopParser.parse("").isEmpty)
        #expect(NettopParser.parse(",bytes_in,bytes_out,\n").isEmpty)
    }

    @Test("Process name without a numeric pid suffix is kept whole")
    func noPidSuffix() {
        let r = NettopParser.parse(",bytes_in,bytes_out,\nkernel_task,9,9,")
        #expect(r["kernel_task"] == NettopParser.Bytes(rx: 9, tx: 9))
    }
}
