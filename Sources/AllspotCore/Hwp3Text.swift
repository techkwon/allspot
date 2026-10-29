// SPDX-License-Identifier: MPL-2.0
// This file contains a conversion table and rules derived from LibreOffice hwpfilter/source/hcode.cxx,
// which is licensed under the Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/).
// This file as a whole is therefore distributed under MPL-2.0. See THIRD_PARTY_NOTICES.md.

import Foundation

// 한글 3.x(한글 3.0/96/97, "HWP Document File V3.00") 문서에서 글자를 꺼낸다.
// 파일 구조는 한글과컴퓨터가 공개한 「한글 문서 파일 구조 3.0」(revision 1.2)을 따랐다.
// 한글 내부 코드 → KS X 1001 변환 규칙과 tgSymbols 표(64개)는
// LibreOffice hwpfilter/source/hcode.cxx(MPL-2.0)의 s_hh2ks·hcharconv를 보고 옮겼다.
// 조합형 한글은 계산으로, 기호·한자는 KS X 1001 위치를 구한 뒤 시스템 EUC-KR 변환으로 바꾼다.
enum Hwp3Text {
    /// 파일 인식 정보(30바이트)
    static let signature: [UInt8] = Array("HWP Document File V3.00 ".utf8) + [0x1A, 1, 2, 3, 4, 5]

    /// 한글 3.x 문서의 본문 글자와 (있으면) 지은이를 꺼낸다. 읽을 수 없으면 nil.
    static func extract(_ data: Data) -> (text: String, author: String?)? {
        let b = [UInt8](data)
        // 인식 정보 30 + 문서 정보 128 + 문서 요약 1008
        guard b.count >= 1166, b.starts(with: signature) else { return nil }
        let encrypted = le16(b, 30 + 96) != 0
        let compressed = b[30 + 124] != 0
        let start = 1166 + le16(b, 30 + 126)       // 정보 블록 다음부터 글꼴·스타일·문단
        let author = hstring(b, from: 158 + 224, count: 56)

        var text = ""
        var ok = false
        if !encrypted, start < b.count {
            var body = Array(b[start...])
            if compressed { body = HwpText.inflate(body) ?? [] }
            (text, ok) = parseBody(body)
        }
        if text.isEmpty, let prv = preview(b) { return (prv, author) }
        if text.isEmpty && !ok { return nil }
        return (text, author)
    }

    // MARK: - 본문

    /// 글꼴 이름 → 스타일 → 문단 리스트. 중간에 깨지면 그때까지 읽은 글자와 false.
    private static func parseBody(_ body: [UInt8]) -> (String, Bool) {
        var r = Reader(b: body)
        for _ in 0..<7 {                             // 언어 7개: 개수(word) + 이름 40바이트씩
            guard let n = r.u16(), n > 0, n < 256, r.skip(n * 40) else { return ("", false) }
        }
        guard let styles = r.u16(), r.skip(styles * 238) else { return ("", false) }
        var out: [UInt16] = []
        out.reserveCapacity(body.count / 4)
        let ok = paraList(&r, &out, depth: 0, emit: true)
        while let last = out.last, last == 10 || last == 32 || last == 9 { out.removeLast() }
        return (String(decoding: out, as: UTF16.self), ok)
    }

    /// 문단 리스트 하나. 글자 수 0인 문단이 끝 표시다.
    private static func paraList(_ r: inout Reader, _ out: inout [UInt16], depth: Int, emit: Bool) -> Bool {
        guard depth < 32 else { return false }
        while true {
            // 문단 정보 43바이트 (+ 문단 모양 187바이트)
            guard let p = r.take(43) else { return false }
            let reuse = r.b[p]
            let nch = le16(r.b, p + 1)
            let nline = le16(r.b, p + 3)
            let ownShapes = r.b[p + 5] != 0
            if nch > 0 && reuse == 0 { guard r.skip(187) else { return false } }
            guard r.skip(nline * 14) else { return false }    // 줄 정보
            if nch == 0 { return true }
            if ownShapes {                                     // 글자 모양: 1이면 앞과 같음, 0이면 31바이트
                for _ in 0..<nch {
                    guard let same = r.u8() else { return false }
                    if same == 0 { guard r.skip(31) else { return false } }
                }
            }
            guard chars(&r, nch, &out, depth: depth, emit: emit) else { return false }
            if emit && out.last != 10 { out.append(10) }
        }
    }

    /// 특수 문자(0~31)가 글자 수에서 차지하는 hchar 칸 수
    private static let wordSize: [Int] = [
        1, 4, 4, 4, 4, 4, 4, 42,
        48, 4, 4, 4, 4, 1, 4, 4,
        4, 4, 4, 4, 4, 4, 12, 5,
        3, 3, 123, 4, 32, 4, 2, 2,
    ]

    private static func chars(_ r: inout Reader, _ nch: Int, _ out: inout [UInt16], depth: Int, emit: Bool) -> Bool {
        var i = 0
        while i < nch {
            guard let hh = r.u16() else { return false }
            if hh > 31 {
                if emit { decode(UInt16(hh), into: &out) }
                i += 1
                continue
            }
            if hh == 13 { return true }                        // 문단 끝
            i += wordSize[hh]
            // 고정 길이: 코드 뒤 n바이트, 마지막 hchar는 다시 같은 코드
            func fixed(_ n: Int) -> Bool { r.skip(n - 2) && r.u16() == hh }
            // 식별 정보 8바이트: 코드, dword, 코드
            func ident() -> Int? {
                guard let n = r.u32(), r.u16() == hh else { return nil }
                return n
            }
            switch hh {
            case 9:
                guard fixed(6) else { return false }
                if emit { out.append(9) }
            case 30, 31:                                       // 묶음·고정폭 빈칸
                guard fixed(2) else { return false }
                if emit { out.append(32) }
            case 7: guard fixed(82) else { return false }      // 날짜 형식
            case 8: guard fixed(94) else { return false }      // 날짜 코드
            case 18, 19, 20, 21: guard fixed(6) else { return false }
            case 22: guard fixed(22) else { return false }     // 메일 머지
            case 23: guard fixed(8) else { return false }      // 글자 겹침
            case 24, 25: guard fixed(4) else { return false }
            case 26: guard fixed(244) else { return false }    // 찾아보기
            case 28: guard fixed(62) else { return false }     // 개요 번호
            case 10:                                           // 표·글상자·수식·버튼
                guard ident() != nil, let p = r.take(84) else { return false }
                let kind = le16(r.b, p + 78)
                let cells = le16(r.b, p + 80)
                guard cells > 0, r.skip(cells * 27) else { return false }
                if emit && out.last != 10 && !out.isEmpty { out.append(10) }
                for _ in 0..<cells {
                    // 수식(2)은 수식 스크립트라 글자로 내지 않는다
                    guard paraList(&r, &out, depth: depth + 1, emit: emit && kind != 2) else { return false }
                }
                guard paraList(&r, &out, depth: depth + 1, emit: emit) else { return false }    // 캡션
            case 11:                                           // 그림: 348바이트 + 추가 정보 + 캡션
                guard ident() != nil, let p = r.take(348) else { return false }
                let extra = le32(r.b, p)
                guard let q = r.take(extra) else { return false }
                if r.b[p + 74] == 3 && extra > 0 {             // 그리기 개체: 글상자 글자만 꺼낸다(실패해도 본문은 계속)
                    var d = Reader(b: Array(r.b[q..<(q + extra)]))
                    var sub: [UInt16] = []
                    if drawing(&d, &sub, depth: depth + 1, emit: emit) || !sub.isEmpty {
                        if !sub.isEmpty && out.last != 10 && !out.isEmpty { out.append(10) }
                        out.append(contentsOf: sub)
                    }
                }
                guard paraList(&r, &out, depth: depth + 1, emit: emit) else { return false }
            case 14:                                           // 선
                guard ident() != nil, r.skip(84) else { return false }
            case 15, 16, 17:                                   // 숨은 설명·머리말/꼬리말·각주/미주
                let extra = hh == 15 ? 8 : (hh == 16 ? 10 : 14)
                guard ident() != nil, r.skip(extra) else { return false }
                if emit && out.last != 10 && !out.isEmpty { out.append(10) }
                guard paraList(&r, &out, depth: depth + 1, emit: emit) else { return false }
            default:                                           // 필드·책갈피·상호참조·예약: 8 + n
                guard let n = ident(), r.skip(n) else { return false }
            }
        }
        return true
    }

    // MARK: - 그리기 개체

    /// 틀 헤더(4 + n) 다음에 개체들이 전위 순회 순서로 이어진다.
    private static func drawing(_ r: inout Reader, _ out: inout [UInt16], depth: Int, emit: Bool) -> Bool {
        guard let n = r.u32(), n >= 24, r.skip(n) else { return false }
        return drawObjects(&r, &out, depth: depth, emit: emit)
    }

    /// 개체 = 공통 헤더(4 + n) + 세부 정보 1(4 + n) + 세부 정보 2(4 + n). 글상자 글자는 문단 리스트로 들어 있다.
    private static func drawObjects(_ r: inout Reader, _ out: inout [UInt16], depth: Int, emit: Bool) -> Bool {
        guard depth < 32 else { return false }
        var count = 0
        while count < 4096 {
            count += 1
            guard let size = r.u32(), size >= 88, let p = r.take(size) else { return false }
            let kind = le16(r.b, p)
            let link = le16(r.b, p + 2)
            let flag = le32(r.b, p + 84)
            // 회전·그라데이션·비트맵·워터마크 속성은 플래그가 있을 때만 붙는다
            var common = 88
            if flag & 0x20000 != 0 && size >= common + 32 { common += 32 }
            if flag & 0x10000 != 0 && size >= common + 28 { common += 28 }
            if flag & 0x40000 != 0 && size >= common + 278 { common += 278 }
            if flag & 0x100000 != 0 && size >= common + 3 { common += 5 }
            if flag & 0x80000 != 0 && size > common + 8 {    // 글상자로 쓰는 도형
                var t = Reader(b: Array(r.b[(p + common + 8)..<(p + size)]))
                _ = paraList(&t, &out, depth: depth + 1, emit: emit)
            }
            guard let n1 = r.u32(), r.skip(n1), let n2 = r.u32(), let q = r.take(n2) else { return false }
            if kind == 6 && n2 > 0 {                          // 글상자
                var t = Reader(b: Array(r.b[q..<(q + n2)]))
                _ = paraList(&t, &out, depth: depth + 1, emit: emit)
            }
            if link & 2 != 0 { guard drawObjects(&r, &out, depth: depth + 1, emit: emit) else { return false } }
            if link & 1 == 0 { return true }
        }
        return false
    }

    // MARK: - 미리보기·문서 요약

    /// 추가 정보 블록 #2의 미리보기 텍스트(0x80000002). 압축 영역 뒤에 있어 파일 끝에서 거꾸로 찾는다.
    private static func preview(_ b: [UInt8]) -> String? {
        guard b.count >= 1166 + 8 else { return nil }
        let floor = max(1166, b.count - (1 << 20))
        var i = b.count - 8
        while i >= floor {
            if b[i] == 2, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 0x80 {
                let n = le32(b, i + 4)
                let end = i + 8 + n
                if n > 0, n % 2 == 0, end <= b.count,
                   end == b.count || (end + 4 <= b.count && b[end + 3] == 0x80 && b[end + 1] == 0 && b[end + 2] == 0) {
                    let t = hstring(b, from: i + 8, count: n / 2, lines: true)
                    if let t { return t }
                }
            }
            i -= 1
        }
        return nil
    }

    /// hchar 문자열(0에서 끝). lines가 참이면 13을 줄바꿈으로 둔다.
    private static func hstring(_ b: [UInt8], from: Int, count: Int, lines: Bool = false) -> String? {
        guard from >= 0, from + count * 2 <= b.count else { return nil }
        var u: [UInt16] = []
        for k in 0..<count {
            let c = UInt16(b[from + k * 2]) | UInt16(b[from + k * 2 + 1]) << 8
            if c == 0 { break }
            if c < 32 {
                if lines && (c == 13 || c == 10) { u.append(10) } else if c == 9 { u.append(9) }
                continue
            }
            decode(c, into: &u)
        }
        let t = String(decoding: u, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - 한글 내부 코드 → 유니코드

    /// 조합형 중성 5비트 값 → 0~20 (없으면 -1)
    private static let jungIndex: [Int8] = [
        -1, -1, -1, 0, 1, 2, 3, 4, -1, -1, 5, 6, 7, 8, 9, 10,
        -1, -1, 11, 12, 13, 14, 15, 16, -1, -1, 17, 18, 19, 20, -1, -1,
    ]
    /// 초성 19개의 호환 자모
    private static let choJamo: [UInt16] = [
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
        0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
    ]
    /// 종성 27개의 호환 자모
    private static let jongJamo: [UInt16] = [
        0x3131, 0x3132, 0x3133, 0x3134, 0x3135, 0x3136, 0x3137, 0x3139, 0x313A, 0x313B,
        0x313C, 0x313D, 0x313E, 0x313F, 0x3140, 0x3141, 0x3142, 0x3144, 0x3145, 0x3146,
        0x3147, 0x3148, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
    ]
    /// 0x37C0~0x37FF 기호의 KS X 1001 코드 (LibreOffice hcode.cxx tblhhtg_ks)
    private static let tgSymbols: [UInt16] = [
        0xC7D1, 0xB1DB, 0xB0FA, 0xC4C4, 0xC7BB, 0xC5CD, 0xA1A1, 0xA1A1,
        0xA2B1, 0xA3DF, 0xA2D5, 0xA6B1, 0xA1B8, 0xA1B9, 0xA3DF, 0xA1DA,
        0xA2C6, 0xA2CC, 0xA2CB, 0xA1A1, 0xA1A1, 0xA6BE, 0xA6B9, 0xA6C1,
        0xA6C2, 0xA6B4, 0xA6AD, 0xA6AF, 0xA6B0, 0xA6C3, 0xA6C4, 0xA1A1,
        0xA6AE, 0xA6B0, 0xA2D7, 0xA1E1, 0xA1D6, 0xA1A1, 0xA6BC, 0xA6B7,
        0xA6B1, 0xA6AE, 0xA6B5, 0xA6B3, 0xA6B2, 0xA6AC, 0xA6B6, 0xA6BA,
        0xA6BF, 0xA6B8, 0xA6BD, 0xA6C5, 0xA6C6, 0xA6C8, 0xA6C7, 0xA6C0,
        0xA6BB, 0xA1A1, 0xA1A1, 0xA1A1, 0xA1E1, 0xA1E1, 0xA1E1, 0xA1E1,
    ]
    /// "한글과컴퓨터" 글자(0x37C0~0x37C5)
    private static let hancom: [UInt16] = [0xD55C, 0xAE00, 0xACFC, 0xCEF4, 0xD4E8, 0xD130]

    /// KS X 1001 기호(0xA1~0xAC행)·한자(0xCA~0xFD행) → 유니코드. 처음 쓸 때 한 번 만든다.
    private static let ksTable: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 94 * 94)
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        for row in Array(0xA1...0xAC) + Array(0xCA...0xFD) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(188)
            for col in 0xA1...0xFE { bytes.append(UInt8(row)); bytes.append(UInt8(col)) }
            let base = (row - 0xA1) * 94
            if let s = String(bytes: bytes, encoding: enc), s.utf16.count == 94, !s.utf16.contains(0xFFFD) {
                for (k, u) in s.utf16.enumerated() { t[base + k] = u }
                continue
            }
            // 빈 칸이 섞인 행은 한 글자씩
            for col in 0xA1...0xFE {
                if let s = String(bytes: [UInt8(row), UInt8(col)], encoding: enc), s.utf16.count == 1,
                   let u = s.utf16.first, u != 0xFFFD {
                    t[base + col - 0xA1] = u
                }
            }
        }
        return t
    }()

    @inline(__always)
    private static func ks(_ code: Int) -> UInt16 {
        let row = code >> 8, col = code & 0xFF
        guard row >= 0xA1, row <= 0xFE, col >= 0xA1, col <= 0xFE else { return 0 }
        return ksTable[(row - 0xA1) * 94 + col - 0xA1]
    }

    /// 글자 하나. 바꿀 수 없는 글자(옛한글 조합, 정의되지 않은 기호)는 건너뛴다.
    static func decode(_ c: UInt16, into out: inout [UInt16]) {
        if c < 0x80 { out.append(c); return }
        if c & 0x8000 != 0 {                               // 조합형 한글: 1 초성5 중성5 종성5
            if c == 0xD3C5 { out.append(0xD55C); return }  // 한컴 고유 "한"
            let cho = Int(c >> 10) & 0x1F, jung = Int(c >> 5) & 0x1F, jong = Int(c) & 0x1F
            if jung < 2 {
                // 낱자 영역: 초성*32 + 종성 순서로 ㄱ~ㅎ 30자가 먼저 온다
                let idx = cho * 32 + jong
                if jung == 0, c < 0xA414, idx < 30 { out.append(0x3131 + UInt16(idx)) }
                return
            }
            let ci = cho >= 2 && cho <= 20 ? cho - 2 : -1
            let vi = Int(jungIndex[jung])
            let ti = jong == 1 ? 0 : (jong >= 2 && jong <= 17 ? jong - 1 : (jong >= 19 && jong <= 29 ? jong - 2 : -1))
            if ci >= 0, vi >= 0, ti >= 0 {
                out.append(UInt16(0xAC00 + (ci * 21 + vi) * 28 + ti))
            } else if cho == 1, vi >= 0, jong == 1 {
                out.append(0x314F + UInt16(vi))           // 모음만
            } else if cho == 1, jung >= 30, jong == 1 {
                out.append(jung == 30 ? 0x318D : 0x318E)  // 아래아(가운뎃점처럼 쓰임)
            } else if ci >= 0, jung == 2, jong == 1 {
                out.append(choJamo[ci])                   // 자음만
            } else if cho == 1, jung == 2, ti > 0 {
                out.append(jongJamo[ti - 1])              // 받침만
            }
            return
        }
        if c >= 0x4000 {                                   // 한자: KS X 1001 한자 4888자 순서
            let idx = Int(c) - 0x4000
            if idx < 4888 {
                let u = ks((0xCA + idx / 94) << 8 | (0xA1 + idx % 94))
                if u != 0 { out.append(u) }
            }
            return
        }
        if c >= 0x3013 && c < 0x3013 + 77 {                // 선 그리기 문자
            switch (Int(c) - 0x3013) % 11 {
            case 9: out.append(0x2D)
            case 10: out.append(0x7C)
            default: out.append(0x2B)
            }
            return
        }
        if c >= 0x2F00 && c <= 0x2F6F && c & 0x0F < 9 {    // 글머리표
            let bases = [0xA1E0, 0xA1DB, 0xA1DE, 0xA1E2, 0xA1E4, 0xA2B7, 0xA2B9]
            let base = bases[min(Int(c - 0x2F00) >> 4, 6)]
            let u = ks(base + (c & 0x0F < 6 ? 0 : 1))
            if u != 0 { out.append(u) }
            return
        }
        if c == 0x81 || c == 0x82 { out.append(0x22); return }
        if c == 0x83 || c == 0x84 { out.append(0x27); return }
        let hi = Int(c >> 8), lo = Int(c & 0xFF)
        var code = 0
        if hi == 0x1F {                                    // 일본 글자(KS 0xAA·0xAB행)
            let row = lo >= 0x60 ? 0xAB : 0xAA
            code = row << 8 | ((lo >= 0x60 ? lo - 0x60 : lo) + 0xA0)
        } else if lo >= 0xC0 {
            return
        } else if hi < 0x34 || hi >= 0x38 {
            if c == 0x309B { out.append(0xFF62) } else if c == 0x309D { out.append(0xFF63) }
            return
        } else if c >= 0x37C0 {
            let k = Int(c) - 0x37C0
            if k < 6 { out.append(hancom[k]); return }
            code = Int(tgSymbols[k])
        } else {                                           // 0x3400부터 한 행에 0x60칸씩
            let h = Int(c) - 0x3400
            var row = h / 0x60 + 0xA1
            if row == 0xAA { row = 0xAC }
            code = row << 8 | (h % 0x60 + 0xA0)
        }
        let u = ks(code)
        if u != 0 { out.append(u) }
    }

    // MARK: - 바이트 읽기

    @inline(__always)
    private static func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }

    @inline(__always)
    private static func le32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// 범위를 넘으면 nil·false를 돌려주는 순차 읽기
    private struct Reader {
        let b: [UInt8]
        var p = 0

        mutating func skip(_ n: Int) -> Bool {
            guard n >= 0, n <= b.count - p else { return false }
            p += n
            return true
        }

        mutating func take(_ n: Int) -> Int? {
            let start = p
            return skip(n) ? start : nil
        }

        mutating func u8() -> UInt8? {
            guard p < b.count else { return nil }
            p += 1
            return b[p - 1]
        }

        mutating func u16() -> Int? {
            guard let o = take(2) else { return nil }
            return le16(b, o)
        }

        mutating func u32() -> Int? {
            guard let o = take(4) else { return nil }
            return le32(b, o)
        }
    }
}
