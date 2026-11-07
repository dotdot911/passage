import ProxyModel

/// Minimal DNS wire-format parser: question plus A/AAAA/CNAME answers.
public struct DNSMessage: Equatable, Sendable {
    public struct Answer: Equatable, Sendable {
        public var name: String
        public var type: UInt16
        public var ttl: UInt32
        /// Dotted IPv4, IPv6 text, or a CNAME target.
        public var value: String
    }

    public var id: UInt16
    public var isResponse: Bool
    public var responseCode: Int
    public var questionName: String
    public var questionType: UInt16
    public var answers: [Answer]

    public static let typeA: UInt16 = 1, typeCNAME: UInt16 = 5, typeAAAA: UInt16 = 28

    public init?(_ b: [UInt8]) {
        guard b.count >= 12 else { return nil }
        id = UInt16(b[0]) << 8 | UInt16(b[1])
        isResponse = b[2] & 0x80 != 0
        responseCode = Int(b[3] & 0x0f)
        let qd = Int(b[4]) << 8 | Int(b[5])
        let an = Int(b[6]) << 8 | Int(b[7])
        guard qd >= 1 else { return nil }
        var pos = 12
        guard let qname = Self.name(b, &pos), pos + 4 <= b.count else { return nil }
        questionName = qname
        questionType = UInt16(b[pos]) << 8 | UInt16(b[pos + 1])
        pos += 4
        for _ in 1..<qd { // skip extra questions (never sent in practice)
            guard Self.name(b, &pos) != nil, pos + 4 <= b.count else { return nil }
            pos += 4
        }
        answers = []
        for _ in 0..<an {
            guard let n = Self.name(b, &pos), pos + 10 <= b.count else { break }
            let type = UInt16(b[pos]) << 8 | UInt16(b[pos + 1])
            let ttl = UInt32(b[pos + 4]) << 24 | UInt32(b[pos + 5]) << 16 | UInt32(b[pos + 6]) << 8 | UInt32(b[pos + 7])
            let rdlen = Int(b[pos + 8]) << 8 | Int(b[pos + 9])
            pos += 10
            guard pos + rdlen <= b.count else { break }
            let rdata = Array(b[pos..<(pos + rdlen)])
            switch type {
            case Self.typeA where rdlen == 4:
                answers.append(Answer(name: n, type: type, ttl: ttl, value: rdata.map(String.init).joined(separator: ".")))
            case Self.typeAAAA where rdlen == 16:
                answers.append(Answer(name: n, type: type, ttl: ttl, value: IPv6Text(rdata)))
            case Self.typeCNAME:
                var p = pos
                if let target = Self.name(b, &p) { answers.append(Answer(name: n, type: type, ttl: ttl, value: target)) }
            default: break
            }
            pos += rdlen
        }
    }

    public static let typeSVCB: UInt16 = 64

    /// True for the DDR probe (RFC 9462) iOS sends to upgrade a resolver to DNS-over-TLS/HTTPS.
    public var isDesignatedResolverDiscovery: Bool {
        !isResponse && questionType == Self.typeSVCB && questionName.lowercased() == "_dns.resolver.arpa"
    }

    /// A NOERROR response with no answers to `query`: header and question echoed, other sections dropped.
    public static func emptyResponse(to query: [UInt8]) -> [UInt8]? {
        guard query.count >= 12 else { return nil }
        var pos = 12
        guard name(query, &pos) != nil, pos + 4 <= query.count else { return nil }
        var r = Array(query[0..<(pos + 4)])
        r[2] = 0x80 | (query[2] & 0x01) // QR; keep RD
        r[3] = 0x80                     // RA, rcode NOERROR
        r[4] = 0; r[5] = 1              // one question
        for i in 6..<12 { r[i] = 0 }    // no answer/authority/additional records
        return r
    }

    /// A response to `query` with one answer per `rdata` (4 bytes for A, 16 for AAAA), all of `type`.
    public static func answerResponse(to query: [UInt8], type: UInt16, rdata: [[UInt8]], ttl: UInt32) -> [UInt8]? {
        guard var r = emptyResponse(to: query) else { return nil }
        r[6] = UInt8(rdata.count >> 8); r[7] = UInt8(rdata.count & 0xff)
        for data in rdata {
            r += [0xc0, 0x0c]                                   // name: pointer to the question
            r += [UInt8(type >> 8), UInt8(type & 0xff), 0, 1]   // type, class IN
            r += [UInt8(ttl >> 24), UInt8(ttl >> 16 & 0xff), UInt8(ttl >> 8 & 0xff), UInt8(ttl & 0xff)]
            r += [UInt8(data.count >> 8), UInt8(data.count & 0xff)] + data
        }
        return r
    }

    /// Reads a (possibly compressed) domain name starting at `pos`; advances `pos` past it.
    static func name(_ b: [UInt8], _ pos: inout Int) -> String? {
        var labels: [String] = []
        var p = pos
        var jumped = false
        var hops = 0
        while true {
            guard p < b.count else { return nil }
            let len = Int(b[p])
            if len == 0 { p += 1; break }
            if len & 0xc0 == 0xc0 {
                guard p + 1 < b.count, hops < 16 else { return nil }
                let target = (len & 0x3f) << 8 | Int(b[p + 1])
                if !jumped { pos = p + 2 }
                jumped = true
                hops += 1
                p = target
                continue
            }
            guard p + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(p + 1)..<(p + 1 + len)], as: UTF8.self))
            p += 1 + len
        }
        if !jumped { pos = p }
        return labels.joined(separator: ".")
    }
}
