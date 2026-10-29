import Foundation
import Compression
import CommonCrypto

/// 한글(HWP 5.0) 문서에서 글자를 꺼낸다.
///   OLE 복합 파일 → FileHeader → BodyText/SectionN 레코드(PARA_TEXT) 순으로 읽고,
///   못 읽으면 PrvText(미리보기 글자)로 대신한다.
enum HwpText {
    /// HWP 5.0 문서의 본문 글자와 (있으면) 작성자를 꺼낸다. 읽을 수 없으면 nil.
    static func extract(_ data: Data) -> (text: String, author: String?)? {
        if data.starts(with: Hwp3Text.signature) { return Hwp3Text.extract(data) }   // 한글 3.x
        guard let cfb = Cfb([UInt8](data)) else { return nil }
        guard let header = cfb.stream(["FileHeader"]), header.count >= 40,
              header.starts(with: Array("HWP Document File".utf8)) else { return nil }
        let version = le32(header, 32)
        guard version >> 24 == 5 else { return nil }
        let props = le32(header, 36)
        let compressed = props & 0x1 != 0
        // 암호(1)·DRM(4)·인증서 암호화(8)·인증서 DRM(10) 문서는 본문을 못 읽는다
        let locked = props & (1 << 1 | 1 << 4 | 1 << 8 | 1 << 10) != 0
        var text: String?
        if !locked {
            if props & 0x4 != 0 {
                text = body(cfb, storage: "ViewText", compressed: compressed, distributed: true)
            } else {
                text = body(cfb, storage: "BodyText", compressed: compressed, distributed: false)
            }
        }
        if text?.isEmpty ?? true, let prv = preview(cfb) { text = prv }
        guard let result = text else { return nil }
        return (result, summaryAuthor(cfb))
    }

    // MARK: - 본문

    /// 구역 스트림을 차례로 읽어 글자를 모은다. 구역을 하나도 못 읽으면 nil.
    private static func body(_ cfb: Cfb, storage: String, compressed: Bool, distributed: Bool) -> String? {
        guard let dir = cfb.find([storage]) else { return nil }
        var sections: [(Int, Int)] = []
        for (name, idx) in cfb.children(of: dir) where name.hasPrefix("Section") {
            if let n = Int(name.dropFirst(7)) { sections.append((n, idx)) }
        }
        sections.sort { $0.0 < $1.0 }
        var out: [UInt16] = []
        var ok = false
        for (_, idx) in sections {
            guard var raw = cfb.read(idx) else { continue }
            if distributed {
                guard let plain = undistribute(raw) else { continue }
                raw = plain
            }
            if compressed {
                guard let inflated = inflate(raw) else { continue }
                raw = inflated
            }
            ok = true
            if out.isEmpty { out.reserveCapacity(raw.count / 3) }
            paraText(raw, into: &out)
        }
        guard ok else { return nil }
        while let last = out.last, last == 10 || last == 32 || last == 9 { out.removeLast() }
        return String(decoding: out, as: UTF16.self)
    }

    /// 레코드 묶음에서 HWPTAG_PARA_TEXT(67)만 골라 글자를 붙인다.
    private static func paraText(_ recs: [UInt8], into out: inout [UInt16]) {
        recs.withUnsafeBufferPointer { p in
            let n = p.count
            var pos = 0
            while pos + 4 <= n {
                let h = UInt32(p[pos]) | UInt32(p[pos + 1]) << 8 | UInt32(p[pos + 2]) << 16 | UInt32(p[pos + 3]) << 24
                pos += 4
                var size = Int(h >> 20)
                if size == 0xFFF {
                    guard pos + 4 <= n else { return }
                    size = Int(UInt32(p[pos]) | UInt32(p[pos + 1]) << 8 | UInt32(p[pos + 2]) << 16 | UInt32(p[pos + 3]) << 24)
                    pos += 4
                }
                guard size <= n - pos else { return }
                if h & 0x3FF == 67 {
                    decodeChars(p, from: pos, count: size / 2, into: &out)
                    if out.last != 10 { out.append(10) }
                }
                pos += size
            }
        }
    }

    /// 글자 조각 하나. 제어 문자 중 문자형(0, 10, 13, 24~31)은 1칸, 나머지(인라인·확장)는 8칸을 차지한다.
    @inline(__always)
    private static func decodeChars(_ p: UnsafeBufferPointer<UInt8>, from start: Int, count: Int, into out: inout [UInt16]) {
        var i = 0
        while i < count {
            let o = start + i * 2
            let c = UInt16(p[o]) | UInt16(p[o + 1]) << 8
            if c >= 32 {
                out.append(c)
                i += 1
                continue
            }
            switch c {
            case 10, 13:
                out.append(10); i += 1
            case 24:
                out.append(45); i += 1          // 하이픈
            case 30, 31:
                out.append(32); i += 1          // 묶음 빈칸·고정폭 빈칸
            case 0, 25...29:
                i += 1
            case 9:
                out.append(9); i += 8           // 탭은 인라인 제어(8칸)
            default:
                i += 8                          // 표·그림·필드 등 확장 제어
            }
        }
    }

    /// raw DEFLATE 풀기. 중간에 깨졌으면 그때까지 풀린 것만 돌려준다.
    static func inflate(_ input: [UInt8]) -> [UInt8]? {
        if input.isEmpty { return [] }
        let s = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { s.deallocate() }
        guard compression_stream_init(s, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(s) }
        let chunk = 1 << 16
        let limit = 128 << 20                   // 풀린 크기 상한(압축 폭탄 방지)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 4)
        return input.withUnsafeBufferPointer { inp -> [UInt8]? in
            s.pointee.src_ptr = inp.baseAddress!
            s.pointee.src_size = inp.count
            var stalls = 0
            while true {
                s.pointee.dst_ptr = buf
                s.pointee.dst_size = chunk
                let st = compression_stream_process(s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - s.pointee.dst_size
                out.append(contentsOf: UnsafeBufferPointer(start: buf, count: produced))
                if out.count > limit { return out }
                switch st {
                case COMPRESSION_STATUS_END:
                    return out
                case COMPRESSION_STATUS_OK:
                    if produced == 0 {
                        stalls += 1
                        if stalls > 2 { return out.isEmpty ? nil : out }
                    } else {
                        stalls = 0
                    }
                default:
                    return out.isEmpty ? nil : out
                }
            }
        }
    }

    /// 배포용 문서의 ViewText 구역 풀기: 첫 레코드(DISTRIBUTE_DOC_DATA, 256바이트)에서 AES 키를 얻고 나머지를 AES-128 ECB로 푼다.
    private static func undistribute(_ s: [UInt8]) -> [UInt8]? {
        guard s.count >= 260 else { return nil }
        let h = le32(s, 0)
        guard h & 0x3FF == 0x10 + 12, h >> 20 == 256 else { return nil }
        var d = Array(s[4..<260])
        let seed = le32(d, 0)
        var state = seed
        func rand() -> UInt32 {
            state = state &* 214013 &+ 2531011
            return (state >> 16) & 0x7FFF
        }
        var key: UInt8 = 0
        var left = 0
        for i in 0..<256 {
            if left == 0 {
                key = UInt8(rand() & 0xFF)
                left = Int(rand() & 0xF) + 1
            }
            d[i] ^= key
            left -= 1
        }
        let off = 4 + Int(seed & 0xF)
        let aesKey = Array(d[off..<off + 16])
        let body = Array(s[260..<(260 + (s.count - 260) / 16 * 16)])
        if body.isEmpty { return [] }
        var plain = [UInt8](repeating: 0, count: body.count)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                         aesKey, kCCKeySizeAES128, nil, body, body.count, &plain, plain.count, &moved)
        guard st == kCCSuccess else { return nil }
        return Array(plain[0..<moved])
    }

    // MARK: - 미리보기·요약 정보

    private static func preview(_ cfb: Cfb) -> String? {
        guard let s = cfb.stream(["PrvText"]), s.count >= 2 else { return nil }
        var u: [UInt16] = []
        u.reserveCapacity(s.count / 2)
        var i = 0
        while i + 1 < s.count {
            let c = UInt16(s[i]) | UInt16(s[i + 1]) << 8
            if c != 0 { u.append(c == 13 ? 10 : c) }
            i += 2
        }
        let t = String(decoding: u, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// OLE 속성 집합에서 PIDSI_AUTHOR(4)
    private static func summaryAuthor(_ cfb: Cfb) -> String? {
        guard let s = cfb.stream(["\u{5}HwpSummaryInformation"]), s.count >= 48, le32(s, 24) >= 1 else { return nil }
        let sec = Int(le32(s, 44))
        guard sec >= 0, sec + 8 <= s.count else { return nil }
        let count = Int(le32(s, sec + 4))
        guard count < 4096 else { return nil }
        for k in 0..<count {
            let e = sec + 8 + k * 8
            guard e + 8 <= s.count else { return nil }
            guard le32(s, e) == 4 else { continue }
            let p = sec + Int(le32(s, e + 4))
            guard p + 8 <= s.count else { return nil }
            let type = le32(s, p)
            let len = Int(le32(s, p + 4))
            var value: String?
            if type == 0x1F {                   // VT_LPWSTR
                guard len <= (s.count - p - 8) / 2 else { return nil }
                var u: [UInt16] = []
                for j in 0..<len {
                    let c = UInt16(s[p + 8 + j * 2]) | UInt16(s[p + 9 + j * 2]) << 8
                    if c == 0 { break }
                    u.append(c)
                }
                value = String(decoding: u, as: UTF16.self)
            } else if type == 0x1E {            // VT_LPSTR
                guard len <= s.count - p - 8 else { return nil }
                var b = Array(s[(p + 8)..<(p + 8 + len)])
                if let z = b.firstIndex(of: 0) { b.removeSubrange(z...) }
                let euckr = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
                value = String(bytes: b, encoding: .utf8) ?? String(bytes: b, encoding: euckr)
            }
            let t = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        return nil
    }

    @inline(__always)
    fileprivate static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

// MARK: - OLE 복합 파일(CFB)

/// 읽기 전용 OLE 복합 파일. 모든 체인은 길이 상한과 범위 검사를 둔다.
private struct Cfb {
    struct Entry {
        let name: String
        let type: UInt8
        let left: Int
        let right: Int
        let child: Int
        let start: UInt32
        let size: Int
    }

    let bytes: [UInt8]
    let shift: Int
    let sectorSize: Int
    let fat: [UInt32]
    let miniFat: [UInt32]
    let miniStream: [UInt8]
    let cutoff: Int
    let entries: [Entry]

    private static let endMark: UInt32 = 0xFFFF_FFFA      // 이 값 이상은 특수 표시(끝·빈칸·FAT·DIFAT)

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 512,
              bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { return nil }
        self.bytes = bytes
        let le16 = { (o: Int) -> Int in Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        let le32 = { (o: Int) -> UInt32 in HwpText.le32(bytes, o) }
        shift = le16(0x1E)
        guard shift == 9 || shift == 12, le16(0x20) == 6 else { return nil }
        sectorSize = 1 << shift
        let perSector = sectorSize / 4
        let maxSectors = bytes.count / sectorSize + 1

        // DIFAT: 머리글 109개 + 추가 DIFAT 섹터
        let numFat = Int(le32(0x2C))
        guard numFat > 0, numFat <= maxSectors else { return nil }
        var fatSectors: [UInt32] = []
        fatSectors.reserveCapacity(numFat)
        for k in 0..<109 where fatSectors.count < numFat {
            let v = le32(0x4C + k * 4)
            if v < Cfb.endMark { fatSectors.append(v) }
        }
        var dif = le32(0x44)
        var hops = 0
        while fatSectors.count < numFat, dif < Cfb.endMark, hops < maxSectors {
            let off = (Int(dif) + 1) << shift
            guard off + sectorSize <= bytes.count else { break }
            for k in 0..<(perSector - 1) where fatSectors.count < numFat {
                let v = le32(off + k * 4)
                if v < Cfb.endMark { fatSectors.append(v) }
            }
            dif = le32(off + sectorSize - 4)
            hops += 1
        }
        guard !fatSectors.isEmpty else { return nil }

        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * perSector)
        for sid in fatSectors {
            let off = (Int(sid) + 1) << shift
            guard off + sectorSize <= bytes.count else {
                // 마지막 섹터가 잘린 파일: 있는 만큼만
                if off < bytes.count {
                    var o = off
                    while o + 4 <= bytes.count { fat.append(le32(o)); o += 4 }
                }
                continue
            }
            bytes.withUnsafeBytes { raw in
                for k in 0..<perSector { fat.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off + k * 4, as: UInt32.self))) }
            }
        }
        self.fat = fat

        // 디렉터리
        guard let dirBytes = Cfb.chain(bytes, shift: shift, fat: fat, start: le32(0x30), size: nil) else { return nil }
        var entries: [Entry] = []
        entries.reserveCapacity(dirBytes.count / 128)
        let big = shift == 12
        var o = 0
        while o + 128 <= dirBytes.count {
            let nameLen = min(Int(dirBytes[o + 0x40]) | Int(dirBytes[o + 0x41]) << 8, 64)
            var u: [UInt16] = []
            var j = 0
            while j + 1 < nameLen {
                let c = UInt16(dirBytes[o + j]) | UInt16(dirBytes[o + j + 1]) << 8
                if c == 0 { break }
                u.append(c)
                j += 2
            }
            let idx = { (p: Int) -> Int in
                let v = HwpText.le32(dirBytes, p)
                return v >= Cfb.endMark ? -1 : Int(v)
            }
            var size = Int(HwpText.le32(dirBytes, o + 0x78))
            if big { size |= Int(HwpText.le32(dirBytes, o + 0x7C)) << 32 }
            entries.append(Entry(name: String(decoding: u, as: UTF16.self), type: dirBytes[o + 0x42],
                                 left: idx(o + 0x44), right: idx(o + 0x48), child: idx(o + 0x4C),
                                 start: HwpText.le32(dirBytes, o + 0x74), size: size))
            o += 128
        }
        guard let root = entries.first, root.type == 5 else { return nil }
        self.entries = entries
        cutoff = Int(le32(0x38))

        // 미니 FAT·미니 스트림(작은 스트림은 64바이트 단위로 여기에 들어 있다)
        var miniFat: [UInt32] = []
        if le32(0x40) > 0, let mf = Cfb.chain(bytes, shift: shift, fat: fat, start: le32(0x3C), size: nil) {
            miniFat.reserveCapacity(mf.count / 4)
            var k = 0
            while k + 4 <= mf.count { miniFat.append(HwpText.le32(mf, k)); k += 4 }
        }
        self.miniFat = miniFat
        if root.size > 0, root.size <= bytes.count,
           let ms = Cfb.chain(bytes, shift: shift, fat: fat, start: root.start, size: root.size) {
            miniStream = ms
        } else {
            miniStream = []
        }
    }

    /// 일반 섹터 체인. size가 nil이면 체인 끝까지 읽는다.
    static func chain(_ bytes: [UInt8], shift: Int, fat: [UInt32], start: UInt32, size: Int?) -> [UInt8]? {
        let ss = 1 << shift
        let want = size ?? Int.max
        var out: [UInt8] = []
        if let size { out.reserveCapacity(size) }
        var sid = start
        var steps = 0
        let maxSteps = bytes.count >> shift     // 순환 체인이어도 파일 크기 이상은 읽지 않는다
        while out.count < want {
            if sid >= endMark { return size == nil ? out : nil }
            guard Int(sid) < fat.count, steps <= maxSteps else { return nil }
            let off = (Int(sid) + 1) << shift
            guard off < bytes.count else { return nil }
            let n = min(ss, want - out.count, bytes.count - off)
            out.append(contentsOf: bytes[off..<(off + n)])
            if n < ss && out.count < want && size != nil { return nil }
            if n < ss && size == nil { return out }
            sid = fat[Int(sid)]
            steps += 1
        }
        return out
    }

    func read(_ index: Int) -> [UInt8]? {
        guard index >= 0, index < entries.count else { return nil }
        let e = entries[index]
        guard e.type == 2 else { return nil }
        if e.size == 0 { return [] }
        if e.size < cutoff {
            guard e.size <= miniStream.count else { return nil }
            var out: [UInt8] = []
            out.reserveCapacity(e.size)
            var sid = e.start
            var steps = 0
            while out.count < e.size {
                guard Int(sid) < miniFat.count, steps <= miniFat.count else { return nil }
                let off = Int(sid) << 6
                guard off < miniStream.count else { return nil }
                let n = min(64, e.size - out.count, miniStream.count - off)
                out.append(contentsOf: miniStream[off..<(off + n)])
                if n < 64 && out.count < e.size { return nil }
                sid = miniFat[Int(sid)]
                steps += 1
            }
            return out
        }
        guard e.size <= bytes.count else { return nil }
        return Cfb.chain(bytes, shift: shift, fat: fat, start: e.start, size: e.size)
    }

    /// 저장소 아래 항목들(이름, 번호). 레드-블랙 트리를 돌며 한 번씩만 방문한다.
    func children(of index: Int) -> [(String, Int)] {
        guard index >= 0, index < entries.count else { return [] }
        var out: [(String, Int)] = []
        var stack = [entries[index].child]
        var seen = Set<Int>()
        while let i = stack.popLast() {
            guard i >= 0, i < entries.count, seen.insert(i).inserted else { continue }
            let e = entries[i]
            out.append((e.name, i))
            stack.append(e.left)
            stack.append(e.right)
        }
        return out
    }

    func find(_ path: [String]) -> Int? {
        var cur = 0
        for part in path {
            let kids = children(of: cur)
            if let hit = kids.first(where: { $0.0 == part }) ?? kids.first(where: { $0.0.uppercased() == part.uppercased() }) {
                cur = hit.1
            } else {
                return nil
            }
        }
        return cur
    }

    func stream(_ path: [String]) -> [UInt8]? {
        guard let i = find(path) else { return nil }
        return read(i)
    }
}
