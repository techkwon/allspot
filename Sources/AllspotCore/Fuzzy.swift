import Foundation

/// 유사 검색 한 낱말.
///   1. 그대로 들어 있으면 가장 높은 점수
///   2. 초성: "ㅂㄱㅅ" → "보고서", "보ㄱㅅ" 처럼 섞어 써도 된다
///   3. 오타: 글자 하나~둘이 빠지거나 더해지거나 바뀌어도 찾는다 (Wu–Manber 비트 병렬 근사 일치)
///   4. 건너뛰기: 글자가 순서대로만 있으면 찾는다 ("rptpdf" → "report.pdf")
/// 점수는 낮을수록 더 비슷하다. nil이면 맞지 않는다.
final class FuzzyMatcher {
    let bytes: [UInt8]
    let scalars: [UInt32]
    /// 오타·건너뛰기까지 허용할지(거짓이면 초성 일치만 본다)
    let tolerant: Bool
    let hasConsonant: Bool
    let maxErrors: Int

    // 검색 중에는 수백만 번 불리므로 표는 모두 고정된 포인터로 둔다(배열 복사·접근 검사 비용을 없앰).
    private let m: Int
    private let keyBytes: UnsafeMutablePointer<UInt8>
    private let pattern: UnsafeMutablePointer<UInt32>
    /// 패턴 글자가 초성 자음이면 그 초성 번호(0~18), 아니면 -1
    private let patternInitial: UnsafeMutablePointer<Int32>
    /// 글자 → 그 글자가 나오는 패턴 위치 비트
    private let asciiMasks: UnsafeMutablePointer<UInt64>
    private let otherCount: Int
    private let otherScalars: UnsafeMutablePointer<UInt32>
    private let otherMasks: UnsafeMutablePointer<UInt64>
    /// 초성 번호 → 그 초성 자음이 나오는 패턴 위치 비트
    private let initialMasks: UnsafeMutablePointer<UInt64>
    private let asciiOnly: Bool
    /// 근사 일치에 필요한, 이름에 들어 있어야 할 패턴 글자 수의 최솟값
    private let required: Int

    static let initialConsonants: [UInt32] = [
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
        0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
    ]

    @inline(__always) static func isConsonant(_ s: UInt32) -> Bool { s >= 0x3131 && s <= 0x314E }

    init(key: [UInt8], tolerant: Bool) {
        bytes = key
        scalars = String(decoding: key, as: UTF8.self).unicodeScalars.map(\.value)
        self.tolerant = tolerant
        hasConsonant = scalars.contains(where: Self.isConsonant)
        m = scalars.count
        asciiOnly = scalars.allSatisfy { $0 < 0x80 }
        if !tolerant || m > 63 {
            maxErrors = 0
        } else if !asciiOnly {
            maxErrors = m >= 6 ? 2 : (m >= 3 ? 1 : 0)
        } else {
            maxErrors = m >= 7 ? 2 : (m >= 4 ? 1 : 0)
        }
        required = m - maxErrors

        keyBytes = .allocate(capacity: max(key.count, 1))
        keyBytes.initialize(from: key, count: key.count)
        pattern = .allocate(capacity: max(m, 1))
        patternInitial = .allocate(capacity: max(m, 1))
        asciiMasks = .allocate(capacity: 128)
        asciiMasks.initialize(repeating: 0, count: 128)
        initialMasks = .allocate(capacity: 19)
        initialMasks.initialize(repeating: 0, count: 19)
        var others: [(UInt32, UInt64)] = []
        for (i, s) in scalars.enumerated() {
            pattern[i] = s
            patternInitial[i] = Int32(Self.initialConsonants.firstIndex(of: s) ?? -1)
            guard i < 64 else { continue }
            let bit = UInt64(1) << UInt64(i)
            if s < 128 {
                asciiMasks[Int(s)] |= bit
            } else if let index = others.firstIndex(where: { $0.0 == s }) {
                others[index].1 |= bit
            } else {
                others.append((s, bit))
            }
            if patternInitial[i] >= 0 { initialMasks[Int(patternInitial[i])] |= bit }
        }
        otherCount = others.count
        otherScalars = .allocate(capacity: max(others.count, 1))
        otherMasks = .allocate(capacity: max(others.count, 1))
        for (i, entry) in others.enumerated() {
            otherScalars[i] = entry.0
            otherMasks[i] = entry.1
        }
    }

    deinit {
        keyBytes.deallocate()
        pattern.deallocate()
        patternInitial.deallocate()
        asciiMasks.deallocate()
        initialMasks.deallocate()
        otherScalars.deallocate()
        otherMasks.deallocate()
    }

    /// 패턴 j번째 글자가 이름 글자 t와 맞는가. 패턴의 자음(ㄱ)은 그 자음으로 시작하는 음절(가, 고…)과도 맞는다.
    @inline(__always) private func same(_ j: Int, _ t: UInt32) -> Bool {
        if pattern[j] == t { return true }
        let initial = patternInitial[j]
        return initial >= 0 && t >= 0xAC00 && t <= 0xD7A3 && Int32((t - 0xAC00) / 588) == initial
    }

    @inline(__always) private func mask(_ c: UInt32) -> UInt64 {
        if c < 128 { return asciiMasks[Int(c)] }
        var result: UInt64 = 0
        for i in 0..<otherCount where otherScalars[i] == c { result |= otherMasks[i] }
        if hasConsonant && c >= 0xAC00 && c <= 0xD7A3 {
            result |= initialMasks[Int((c - 0xAC00) / 588)]
        }
        return result
    }

    func score(_ text: UnsafePointer<UInt8>, _ length: Int, _ scratch: inout PathScratch) -> Int? {
        guard m > 0 else { return 0 }
        if let found = memmem(text, length, keyBytes, bytes.count) {
            return UnsafeRawPointer(text) == UnsafeRawPointer(found) ? 0 : 1
        }
        guard m <= 63, tolerant || hasConsonant else { return nil }
        // 패턴 글자가 이름에 충분히 들어 있지 않으면 바로 버린다(대부분의 이름이 여기서 걸러진다).
        let need = tolerant ? required : m
        if asciiOnly {
            var seen: UInt64 = 0
            for i in 0..<length { seen |= asciiMasks[Int(text[i] & 0x7F)] & (text[i] < 0x80 ? ~0 : 0) }
            if seen.nonzeroBitCount < need { return nil }
        }
        let n = scratch.decode(text, length)
        let t = scratch.scalars
        if !asciiOnly {
            var seen: UInt64 = 0
            for i in 0..<n { seen |= mask(t[i]) }
            if seen.nonzeroBitCount < need { return nil }
        }

        if hasConsonant, n >= m {
            // 초성(과 음절이 섞인) 패턴을 이름의 각 위치에 맞춰 본다.
            for start in 0...(n - m) {
                var j = 0
                while j < m && same(j, t[start + j]) { j += 1 }
                if j == m { return start == 0 ? 3 : 5 }
            }
        }
        guard tolerant, m >= 2 else { return nil }

        if maxErrors > 0, let errors = approximate(t, n) { return 10 * errors }
        if m >= 3 {
            // 순서대로만 있으면 맞다. 흩어진 정도(span)가 클수록 점수가 나쁘다.
            var j = 0
            var first = -1
            var last = 0
            var i = 0
            while i < n && j < m {
                if same(j, t[i]) {
                    if first < 0 { first = i }
                    last = i
                    j += 1
                }
                i += 1
            }
            if j == m {
                let span = last - first + 1
                if span <= m * 4 { return 30 + min(span - m, 60) }
            }
        }
        return nil
    }

    /// 최대 maxErrors번의 삽입·삭제·바꿈으로 패턴이 이름 어딘가와 맞으면 가장 적은 오류 수를 돌려준다.
    private func approximate(_ t: UnsafeMutablePointer<UInt32>, _ n: Int) -> Int? {
        let k = maxErrors
        let goal = UInt64(1) << UInt64(m - 1)
        var r0: UInt64 = 0, r1: UInt64 = 1, r2: UInt64 = 3
        var best = Int.max
        for i in 0..<n {
            let b = mask(t[i])
            let old0 = r0, old1 = r1
            r0 = ((r0 << 1) | 1) & b
            r1 = (((r1 << 1) | 1) & b) | old0 | (old0 << 1) | 1 | (r0 << 1)
            if k >= 2 {
                r2 = (((r2 << 1) | 1) & b) | old1 | (old1 << 1) | 1 | (r1 << 1)
            }
            if r0 & goal != 0 { return 0 }
            if r1 & goal != 0 { best = 1 }
            if k >= 2 && r2 & goal != 0 { best = min(best, 2) }
        }
        return best <= k ? best : nil
    }
}

extension PathScratch {
    /// UTF-8 바이트를 유니코드 글자 번호로 풀어 scalars에 담고 개수를 돌려준다.
    @inline(__always) mutating func decode(_ text: UnsafePointer<UInt8>, _ length: Int) -> Int {
        var count = 0
        var i = 0
        while i < length && count < scalarCapacity {
            let b0 = UInt32(text[i])
            var value: UInt32
            if b0 < 0x80 {
                value = b0; i += 1
            } else if b0 < 0xE0, i + 1 < length {
                value = (b0 & 0x1F) << 6 | UInt32(text[i + 1] & 0x3F); i += 2
            } else if b0 < 0xF0, i + 2 < length {
                value = (b0 & 0x0F) << 12 | UInt32(text[i + 1] & 0x3F) << 6 | UInt32(text[i + 2] & 0x3F); i += 3
            } else if i + 3 < length {
                value = (b0 & 0x07) << 18 | UInt32(text[i + 1] & 0x3F) << 12 | UInt32(text[i + 2] & 0x3F) << 6 | UInt32(text[i + 3] & 0x3F); i += 4
            } else {
                value = b0; i += 1
            }
            scalars[count] = value
            count += 1
        }
        return count
    }
}
