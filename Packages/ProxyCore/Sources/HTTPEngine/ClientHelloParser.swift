/// Extracts SNI and ALPN from the first TLS record without consuming it.
public enum ClientHelloParser {
    public struct Hello: Equatable, Sendable {
        public var serverName: String?
        public var alpn: [String]
        public init(serverName: String?, alpn: [String]) { self.serverName = serverName; self.alpn = alpn }
    }

    public enum Result: Equatable, Sendable {
        case hello(Hello)
        case needMoreData
        case notTLS
    }

    public static func parse(_ b: [UInt8]) -> Result {
        guard let first = b.first else { return .needMoreData }
        guard first == 0x16 else { return .notTLS }
        guard b.count >= 5 else { return .needMoreData }
        guard b[1] == 0x03 else { return .notTLS }
        let recordLen = Int(b[3]) << 8 | Int(b[4])
        guard b.count >= 5 + recordLen else { return .needMoreData }
        var r = Reader(bytes: b, at: 5, end: 5 + recordLen)
        guard r.u8() == 0x01 else { return .notTLS } // ClientHello
        guard let hsLen = r.u24(), hsLen <= recordLen - 4 else { return .notTLS }
        r.end = r.pos + hsLen
        guard r.skip(2 + 32),                         // client_version + random
              let sid = r.u8(), r.skip(Int(sid)),
              let cs = r.u16(), r.skip(Int(cs)),
              let comp = r.u8(), r.skip(Int(comp)) else { return .notTLS }
        var hello = Hello(serverName: nil, alpn: [])
        guard let extTotal = r.u16() else { return .hello(hello) }
        let extEnd = min(r.end, r.pos + Int(extTotal))
        while r.pos + 4 <= extEnd {
            guard let type = r.u16(), let len = r.u16() else { break }
            let next = r.pos + Int(len)
            guard next <= extEnd else { break }
            var e = Reader(bytes: b, at: r.pos, end: next)
            switch type {
            case 0x0000: // server_name
                _ = e.u16()
                while e.pos + 3 <= e.end {
                    guard let nameType = e.u8(), let nameLen = e.u16(), let name = e.bytes(Int(nameLen)) else { break }
                    if nameType == 0 { hello.serverName = String(decoding: name, as: UTF8.self) }
                }
            case 0x0010: // ALPN
                _ = e.u16()
                while e.pos < e.end {
                    guard let l = e.u8(), let p = e.bytes(Int(l)) else { break }
                    hello.alpn.append(String(decoding: p, as: UTF8.self))
                }
            default: break
            }
            r.pos = next
        }
        return .hello(hello)
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos: Int
        var end: Int
        init(bytes: [UInt8], at: Int, end: Int) { self.bytes = bytes; self.pos = at; self.end = end }
        mutating func u8() -> UInt8? { guard pos + 1 <= end else { return nil }; defer { pos += 1 }; return bytes[pos] }
        mutating func u16() -> UInt16? {
            guard pos + 2 <= end else { return nil }
            defer { pos += 2 }
            return UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
        }
        mutating func u24() -> Int? {
            guard pos + 3 <= end else { return nil }
            defer { pos += 3 }
            return Int(bytes[pos]) << 16 | Int(bytes[pos + 1]) << 8 | Int(bytes[pos + 2])
        }
        mutating func skip(_ n: Int) -> Bool { guard pos + n <= end else { return false }; pos += n; return true }
        mutating func bytes(_ n: Int) -> ArraySlice<UInt8>? {
            guard pos + n <= end else { return nil }
            defer { pos += n }
            return bytes[pos..<pos + n]
        }
    }
}
