import Testing
@testable import DBCore

@Suite struct CellDecoderTests {
    typealias O = CellDecoder.OID
    func d(_ oid: UInt32, _ bytes: [UInt8]) -> String { CellDecoder.decode(oid: oid, bytes: bytes).displayString }
    func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

    @Test func nullAndText() {
        #expect(CellDecoder.decode(oid: O.text, bytes: nil) == .null)
        #expect(d(O.text, Array("héllo".utf8)) == "héllo")
        #expect(d(O.varchar, Array("x".utf8)) == "x")
    }

    @Test func booleansAndIntegers() {
        #expect(d(O.bool, [1]) == "true")
        #expect(d(O.bool, [0]) == "false")
        #expect(d(O.int2, be(Int16(-3))) == "-3")
        #expect(d(O.int4, be(Int32(123456))) == "123456")
        #expect(d(O.int8, be(Int64.min)) == "-9223372036854775808")
        #expect(d(O.oid, be(UInt32.max)) == "4294967295")
    }

    @Test func floats() {
        #expect(d(O.float8, be(1.5.bitPattern)) == "1.5")
        #expect(d(O.float8, be(3.0.bitPattern)) == "3")
        #expect(d(O.float4, be(Float(0.25).bitPattern)) == "0.25")
        #expect(d(O.float8, be(Double.nan.bitPattern)) == "NaN")
        #expect(d(O.float8, be((-Double.infinity).bitPattern)) == "-Infinity")
    }

    func numeric(ndigits: UInt16, weight: Int16, sign: UInt16, dscale: UInt16, _ digits: [UInt16]) -> [UInt8] {
        var bytes: [UInt8] = be(ndigits)
        bytes += be(UInt16(bitPattern: weight))
        bytes += be(sign)
        bytes += be(dscale)
        for digit in digits { bytes += be(digit) }
        return bytes
    }

    @Test func numerics() {
        // 12345.678 → digits [1, 2345, 6780], weight 1, dscale 3
        #expect(d(O.numeric, numeric(ndigits: 3, weight: 1, sign: 0, dscale: 3, [1, 2345, 6780])) == "12345.678")
        // -0.0012 → digits [12], weight -1, dscale 4
        #expect(d(O.numeric, numeric(ndigits: 1, weight: -1, sign: 0x4000, dscale: 4, [12])) == "-0.0012")
        // 10000 → digits [1], weight 1, dscale 0
        #expect(d(O.numeric, numeric(ndigits: 1, weight: 1, sign: 0, dscale: 0, [1])) == "10000")
        // 0.00 → no digits, dscale 2
        #expect(d(O.numeric, numeric(ndigits: 0, weight: 0, sign: 0, dscale: 2, [])) == "0.00")
        #expect(d(O.numeric, numeric(ndigits: 0, weight: 0, sign: 0xC000, dscale: 0, [])) == "NaN")
    }

    @Test func uuidAndBytea() {
        let bytes: [UInt8] = [0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3, 0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00]
        #expect(d(O.uuid, bytes) == "123e4567-e89b-12d3-a456-426614174000")
        #expect(d(O.bytea, [0xde, 0xad, 0x01]) == "\\xdead01")
    }

    @Test func json() {
        #expect(d(O.json, Array("{\"a\":1}".utf8)) == "{\"a\":1}")
        #expect(d(O.jsonb, [1] + Array("{\"a\": 1}".utf8)) == "{\"a\": 1}")
    }

    @Test func dates() {
        #expect(d(O.date, be(Int32(0))) == "2000-01-01")
        #expect(d(O.date, be(Int32(9_132))) == "2025-01-01")
        #expect(d(O.date, be(Int32(-1))) == "1999-12-31")
        #expect(d(O.date, be(Int32.max)) == "infinity")
    }

    @Test func times() {
        let seconds: Int64 = 13 * 3600 + 5 * 60 + 9
        let micros: Int64 = seconds * 1_000_000 + 500_000
        #expect(d(O.time, be(micros)) == "13:05:09.5")
        var tz: [UInt8] = be(Int64(3_600_000_000))
        tz += be(Int32(-7200))
        #expect(d(O.timetz, tz) == "01:00:00+02")
    }

    @Test func timestamps() {
        let day: Int64 = 9_132 * 86_400_000_000
        let noon: Int64 = 12 * 3600 * 1_000_000
        let micros: Int64 = day + noon + 123
        #expect(d(O.timestamp, be(micros)) == "2025-01-01 12:00:00.000123")
        #expect(d(O.timestamptz, be(micros)) == "2025-01-01 12:00:00.000123+00")
        #expect(d(O.timestamp, be(Int64(-1))) == "1999-12-31 23:59:59.999999")
    }

    @Test func intervals() {
        var bytes: [UInt8] = be(Int64(3_723_000_000))
        bytes += be(Int32(3))
        bytes += be(Int32(14))
        #expect(d(O.interval, bytes) == "1 year 2 mons 3 days 01:02:03")
        var oneDay: [UInt8] = be(Int64(0))
        oneDay += be(Int32(1))
        oneDay += be(Int32(0))
        #expect(d(O.interval, oneDay) == "1 day")
    }

    @Test func inet() {
        #expect(d(O.inet, [2, 32, 0, 4, 192, 168, 1, 10]) == "192.168.1.10")
        #expect(d(O.cidr, [2, 24, 1, 4, 10, 0, 0, 0]) == "10.0.0.0/24")
        let v6: [UInt8] = [3, 128, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        #expect(d(O.inet, v6) == "::1")
    }

    @Test func unknownType() {
        #expect(d(600, [1, 2, 3]) == "‹type 600›")
    }
}
