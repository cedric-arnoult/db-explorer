import Foundation

/// Converts Postgres binary-format values into display text, by type OID.
public enum CellDecoder {
    public enum OID {
        public static let bool: UInt32 = 16
        public static let bytea: UInt32 = 17
        public static let char: UInt32 = 18
        public static let name: UInt32 = 19
        public static let int8: UInt32 = 20
        public static let int2: UInt32 = 21
        public static let int4: UInt32 = 23
        public static let text: UInt32 = 25
        public static let oid: UInt32 = 26
        public static let json: UInt32 = 114
        public static let xml: UInt32 = 142
        public static let float4: UInt32 = 700
        public static let float8: UInt32 = 701
        public static let money: UInt32 = 790
        public static let inet: UInt32 = 869
        public static let cidr: UInt32 = 650
        public static let bpchar: UInt32 = 1042
        public static let varchar: UInt32 = 1043
        public static let date: UInt32 = 1082
        public static let time: UInt32 = 1083
        public static let timestamp: UInt32 = 1114
        public static let timestamptz: UInt32 = 1184
        public static let interval: UInt32 = 1186
        public static let timetz: UInt32 = 1266
        public static let numeric: UInt32 = 1700
        public static let uuid: UInt32 = 2950
        public static let jsonb: UInt32 = 3802
        public static let unknown: UInt32 = 705
        public static let regclass: UInt32 = 2205
        public static let regtype: UInt32 = 2206
    }

    /// Decodes one binary value to text. `nil` bytes mean SQL NULL.
    public static func decode(oid: UInt32, bytes: [UInt8]?) -> CellValue {
        guard let bytes else { return .null }
        return .text(string(oid: oid, bytes: bytes))
    }

    static func string(oid: UInt32, bytes b: [UInt8]) -> String {
        switch oid {
        case OID.text, OID.varchar, OID.bpchar, OID.name, OID.json, OID.xml, OID.unknown:
            return utf8(b)
        case OID.char:
            return utf8(b)
        case OID.bool:
            return b.first == 1 ? "true" : "false"
        case OID.int2 where b.count == 2:
            return String(Int16(bitPattern: UInt16(be: b)))
        case OID.int4 where b.count == 4:
            return String(Int32(bitPattern: UInt32(be: b)))
        case OID.oid where b.count == 4, OID.regclass where b.count == 4, OID.regtype where b.count == 4:
            return String(UInt32(be: b))
        case OID.int8 where b.count == 8:
            return String(Int64(bitPattern: UInt64(be: b)))
        case OID.float4 where b.count == 4:
            return formatFloat(Double(Float(bitPattern: UInt32(be: b))))
        case OID.float8 where b.count == 8:
            return formatFloat(Double(bitPattern: UInt64(be: b)))
        case OID.money where b.count == 8:
            let cents = Int64(bitPattern: UInt64(be: b))
            let sign = cents < 0 ? "-" : ""
            let abs = cents.magnitude
            return "\(sign)\(abs / 100).\(String(format: "%02d", Int(abs % 100)))"
        case OID.numeric:
            return decodeNumeric(b) ?? hexPlaceholder(oid)
        case OID.uuid where b.count == 16:
            return decodeUUID(b)
        case OID.jsonb:
            return b.first == 1 ? utf8(Array(b.dropFirst())) : hexPlaceholder(oid)
        case OID.bytea:
            return "\\x" + b.map { String(format: "%02x", $0) }.joined()
        case OID.date where b.count == 4:
            return formatDate(days: Int64(Int32(bitPattern: UInt32(be: b))))
        case OID.time where b.count == 8:
            return formatTime(micros: Int64(bitPattern: UInt64(be: b)))
        case OID.timetz where b.count == 12:
            let micros = Int64(bitPattern: UInt64(be: Array(b[0..<8])))
            // Offset is stored in seconds *west* of UTC.
            let offset = -Int(Int32(bitPattern: UInt32(be: Array(b[8..<12]))))
            return formatTime(micros: micros) + formatOffset(offset)
        case OID.timestamp where b.count == 8:
            return formatTimestamp(micros: Int64(bitPattern: UInt64(be: b)), withZone: false)
        case OID.timestamptz where b.count == 8:
            return formatTimestamp(micros: Int64(bitPattern: UInt64(be: b)), withZone: true)
        case OID.interval where b.count == 16:
            return formatInterval(
                micros: Int64(bitPattern: UInt64(be: Array(b[0..<8]))),
                days: Int32(bitPattern: UInt32(be: Array(b[8..<12]))),
                months: Int32(bitPattern: UInt32(be: Array(b[12..<16])))
            )
        case OID.inet, OID.cidr:
            return decodeInet(b, isCIDR: oid == OID.cidr) ?? hexPlaceholder(oid)
        default:
            return hexPlaceholder(oid)
        }
    }

    public static func hexPlaceholder(_ oid: UInt32) -> String { "‹type \(oid)›" }

    private static func utf8(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    private static func formatFloat(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    // MARK: numeric

    static func decodeNumeric(_ b: [UInt8]) -> String? {
        guard b.count >= 8 else { return nil }
        let ndigits = Int(UInt16(be: Array(b[0..<2])))
        let weight = Int(Int16(bitPattern: UInt16(be: Array(b[2..<4]))))
        let sign = UInt16(be: Array(b[4..<6]))
        let dscale = Int(UInt16(be: Array(b[6..<8])))
        guard b.count >= 8 + ndigits * 2 else { return nil }
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }
        let digits = (0..<ndigits).map { Int(UInt16(be: Array(b[(8 + $0 * 2)..<(10 + $0 * 2)]))) }

        var intPart = ""
        if weight < 0 {
            intPart = "0"
        } else {
            for i in 0...weight {
                let d = i < digits.count ? digits[i] : 0
                intPart += i == 0 ? String(d) : String(format: "%04d", d)
            }
        }
        var fracPart = ""
        if dscale > 0 {
            var i = weight + 1
            while fracPart.count < dscale {
                let d = (i >= 0 && i < digits.count) ? digits[i] : 0
                fracPart += String(format: "%04d", d)
                i += 1
            }
            fracPart = String(fracPart.prefix(dscale))
        }
        var result = intPart
        if !fracPart.isEmpty { result += "." + fracPart }
        if sign == 0x4000 && digits.contains(where: { $0 != 0 }) { result = "-" + result }
        return result
    }

    // MARK: uuid

    private static func decodeUUID(_ b: [UInt8]) -> String {
        let hex = b.map { String(format: "%02x", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
            .map { $0.joined() }.joined(separator: "-")
    }

    // MARK: inet

    private static func decodeInet(_ b: [UInt8], isCIDR: Bool) -> String? {
        guard b.count >= 4 else { return nil }
        let family = b[0], bits = Int(b[1]), n = Int(b[3])
        guard b.count >= 4 + n else { return nil }
        let addr = Array(b[4..<(4 + n)])
        let text: String
        if family == 2, n == 4 {
            text = addr.map(String.init).joined(separator: ".")
            return (bits == 32 && !isCIDR) ? text : "\(text)/\(bits)"
        } else if family == 3, n == 16 {
            var groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(addr[$0]) << 8 | UInt16(addr[$0 + 1]), radix: 16) }
            // Compress the longest run of zero groups.
            var bestStart = -1, bestLen = 0, curStart = -1, curLen = 0
            for (i, g) in groups.enumerated() {
                if g == "0" {
                    if curStart < 0 { curStart = i; curLen = 0 }
                    curLen += 1
                    if curLen > bestLen { bestLen = curLen; bestStart = curStart }
                } else { curStart = -1; curLen = 0 }
            }
            if bestLen >= 2 {
                let head = groups[..<bestStart].joined(separator: ":")
                let tail = groups[(bestStart + bestLen)...].joined(separator: ":")
                text = head + "::" + tail
            } else {
                text = groups.joined(separator: ":")
            }
            groups.removeAll()
            return (bits == 128 && !isCIDR) ? text : "\(text)/\(bits)"
        }
        return nil
    }

    // MARK: date/time (Postgres epoch is 2000-01-01)

    private static let postgresEpochJulian: Int64 = 2_451_545
    private static let microsPerDay: Int64 = 86_400_000_000

    private static func formatDate(days: Int64) -> String {
        if days == Int64(Int32.max) { return "infinity" }
        if days == Int64(Int32.min) { return "-infinity" }
        let (y, m, d) = civil(fromJulian: days + postgresEpochJulian)
        return formatYMD(y, m, d)
    }

    private static func formatYMD(_ y: Int64, _ m: Int64, _ d: Int64) -> String {
        if y <= 0 {
            return String(format: "%04lld-%02lld-%02lld BC", 1 - y, m, d)
        }
        return String(format: "%04lld-%02lld-%02lld", y, m, d)
    }

    private static func formatTime(micros: Int64) -> String {
        let totalSeconds = micros / 1_000_000
        let frac = micros % 1_000_000
        var s = String(format: "%02lld:%02lld:%02lld", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
        if frac != 0 {
            var f = String(format: "%06lld", frac)
            while f.hasSuffix("0") { f.removeLast() }
            s += "." + f
        }
        return s
    }

    private static func formatOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let a = abs(seconds)
        var s = sign + String(format: "%02d", a / 3600)
        if a % 3600 != 0 { s += String(format: ":%02d", (a / 60) % 60) }
        return s
    }

    private static func formatTimestamp(micros: Int64, withZone: Bool) -> String {
        if micros == Int64.max { return "infinity" }
        if micros == Int64.min { return "-infinity" }
        var days = micros / microsPerDay
        var time = micros % microsPerDay
        if time < 0 { time += microsPerDay; days -= 1 }
        let (y, m, d) = civil(fromJulian: days + postgresEpochJulian)
        var date = formatYMD(y, m, d)
        var bc = ""
        if date.hasSuffix(" BC") { date.removeLast(3); bc = " BC" }
        return date + " " + formatTime(micros: time) + (withZone ? "+00" : "") + bc
    }

    private static func formatInterval(micros: Int64, days: Int32, months: Int32) -> String {
        var parts: [String] = []
        let years = months / 12, mons = months % 12
        func plural(_ n: Int32, _ unit: String) -> String { "\(n) \(unit)\(abs(n) == 1 ? "" : "s")" }
        if years != 0 { parts.append(plural(years, "year")) }
        if mons != 0 { parts.append(plural(mons, "mon")) }
        if days != 0 { parts.append(plural(days, "day")) }
        if micros != 0 || parts.isEmpty {
            let neg = micros < 0
            parts.append((neg ? "-" : "") + formatTime(micros: abs(micros)))
        }
        return parts.joined(separator: " ")
    }

    /// Julian day number → proleptic Gregorian (y, m, d). Same algorithm as Postgres `j2date`.
    private static func civil(fromJulian jd: Int64) -> (Int64, Int64, Int64) {
        var julian = jd + 32044
        var quad = julian / 146097
        let extra = (julian - quad * 146097) * 4 + 3
        julian += 60 + quad * 3 + extra / 146097
        quad = julian / 1461
        julian -= quad * 1461
        var y = julian * 4 / 1461
        julian = (y != 0) ? ((julian + 305) % 365) : ((julian + 306) % 366)
        julian += 123
        y += quad * 4
        let year = y - 4800
        quad = julian * 2141 / 65536
        let day = julian - 7834 * quad / 256
        let month = (quad + 10) % 12 + 1
        return (year, month, day)
    }
}

extension FixedWidthInteger {
    /// Reads a big-endian integer from exactly `MemoryLayout<Self>.size` bytes.
    init(be bytes: [UInt8]) {
        var v: Self = 0
        for byte in bytes.prefix(MemoryLayout<Self>.size) { v = v << 8 | Self(byte) }
        self = v
    }
}
