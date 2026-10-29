import Foundation

public struct QueryError: Error, CustomStringConvertible {
    public let description: String
}

/// Everything과 비슷한 검색 문법.
///   공백 = 그리고(AND), | = 또는(OR), ! = 제외(NOT), "따옴표" = 공백이 든 구절
///   ~낱말 또는 fuzzy:낱말 = 유사 검색(오타·건너뛰기), ㅂㄱㅅ = 초성 검색
///   * ? = 와일드카드(이름 전체와 비교), / 가 들어가면 전체 경로와 비교
///   ext:pdf;docx  path:문서/2026  regex:^IMG_\d+  file:  folder:
///   size:>10mb  size:1mb..1gb  size:empty
///   dm:today  dm:yesterday  dm:thisweek  dm:thismonth  dm:thisyear  dm:7d  dm:>2026-01-01  dm:2026-01-01..2026-02-01
///   kind:image|video|audio|doc|archive|code|folder
///   content:예산  tag:빨강  author:홍길동  taken:2026-05  spotlight:<Spotlight 질의>  (이름 색인 밖에서 찾는 조건)
public final class CompiledQuery: @unchecked Sendable {
    enum Predicate {
        case substring(UnsafeBufferPointer<UInt8>)
        case wildcard(UnsafeBufferPointer<UInt8>)
        case regex(Int)
        case ext(UnsafeBufferPointer<UnsafeBufferPointer<UInt8>>)
        case isFile
        case isFolder
        case size(Int64, Int64)
        case modified(Int64, Int64)
        case fuzzy(Int)
        case external(Int)
    }

    struct Alternative {
        let predicate: Predicate
        let negated: Bool
        let inPath: Bool
    }

    let alternatives: UnsafeMutableBufferPointer<Alternative>
    let clauseEnds: UnsafeMutableBufferPointer<Int>
    let regexes: [NSRegularExpression]
    let fuzzies: [FuzzyMatcher]
    /// 검색 스레드들이 같은 객체의 참조 수를 동시에 올리고 내리면 서로 막혀 수십 배 느려진다.
    /// fuzzies가 살아 있게 붙들고, 검색 중에는 참조 수를 건드리지 않는 이 표로 부른다.
    private let fuzzyRefs: UnsafeMutableBufferPointer<Unmanaged<FuzzyMatcher>>
    let needsPath: Bool
    /// 이름 색인 밖에서 답을 구해 와야 하는 조건들
    public let externalTerms: [ExternalTerm]
    /// 검색하는 동안 조건마다 맞는 항목 id 비트맵(FileIndex.search가 채우고 비운다)
    var externalBits: UnsafeMutablePointer<UnsafeMutablePointer<UInt64>>?
    /// 유사·초성 낱말이 있으면 이름순 대신 비슷한 순서로 늘어놓는다.
    public let ranksByRelevance: Bool
    private var owned: [UnsafeMutableRawPointer] = []

    public var isEmpty: Bool { clauseEnds.isEmpty }

    fileprivate init(clauses: [[Alternative]], regexes: [NSRegularExpression], fuzzies: [FuzzyMatcher], externalTerms: [ExternalTerm], owned: [UnsafeMutableRawPointer]) {
        let flat = clauses.flatMap { $0 }
        alternatives = .allocate(capacity: flat.count)
        _ = alternatives.initialize(from: flat)
        clauseEnds = .allocate(capacity: clauses.count)
        var end = 0
        for (i, clause) in clauses.enumerated() {
            end += clause.count
            clauseEnds[i] = end
        }
        self.regexes = regexes
        self.fuzzies = fuzzies
        self.externalTerms = externalTerms
        fuzzyRefs = .allocate(capacity: max(fuzzies.count, 1))
        for (i, matcher) in fuzzies.enumerated() { fuzzyRefs[i] = Unmanaged.passUnretained(matcher) }
        self.owned = owned
        needsPath = flat.contains { $0.inPath }
        ranksByRelevance = flat.contains { alternative in
            if case .fuzzy = alternative.predicate, !alternative.negated { return true }
            return false
        }
    }

    deinit {
        alternatives.deallocate()
        clauseEnds.deallocate()
        fuzzyRefs.deallocate()
        for pointer in owned { pointer.deallocate() }
    }

    /// fuzzy가 참이면 일반 낱말을 모두 유사 검색으로 찾는다.
    public static func compile(_ text: String, fuzzy: Bool = false, now: Date = Date()) throws -> CompiledQuery {
        try compile(segments: [(text, fuzzy)], now: now)
    }

    /// 여러 검색어를 모두 만족하는(AND) 하나의 검색으로 만든다. 검색 내 검색에 쓴다.
    public static func compile(segments: [(String, Bool)], now: Date = Date()) throws -> CompiledQuery {
        var parser = QueryParser(now: now)
        return try parser.parse(segments)
    }

    /// 비슷한 정도(낮을수록 비슷함). 유사·초성 낱말의 점수를 더한다.
    func relevance(_ i: Int, _ v: IndexView, _ scratch: inout PathScratch) -> Int {
        var total = 0
        let (p, n) = v.key(i)
        for a in alternatives {
            guard case .fuzzy(let f) = a.predicate, !a.negated else { continue }
            total += fuzzyRefs[f]._withUnsafeGuaranteedRef { $0.score(p, n, &scratch) } ?? 100
        }
        return total
    }

    // MARK: - 평가

    @inline(__always) func matches(_ i: Int, _ v: IndexView, _ scratch: inout PathScratch) -> Bool {
        scratch.valid = false
        var start = 0
        for c in 0..<clauseEnds.count {
            let end = clauseEnds[c]
            var ok = false
            var j = start
            while j < end {
                if evaluate(alternatives[j], i, v, &scratch) { ok = true; break }
                j += 1
            }
            if !ok { return false }
            start = end
        }
        return true
    }

    @inline(__always) private func text(_ a: Alternative, _ i: Int, _ v: IndexView, _ scratch: inout PathScratch) -> (UnsafePointer<UInt8>, Int) {
        if a.inPath {
            if !scratch.valid { scratch.build(i, v) }
            return (UnsafePointer(scratch.buffer), scratch.length)
        }
        let (p, n) = v.key(i)
        return (UnsafePointer(p), n)
    }

    @inline(__always) private func evaluate(_ a: Alternative, _ i: Int, _ v: IndexView, _ scratch: inout PathScratch) -> Bool {
        let result: Bool
        switch a.predicate {
        case .substring(let pattern):
            let (p, n) = text(a, i, v, &scratch)
            result = pattern.count == 0 || (n >= pattern.count && memmem(p, n, pattern.baseAddress, pattern.count) != nil)
        case .wildcard(let pattern):
            let (p, n) = text(a, i, v, &scratch)
            result = Wildcard.match(pattern, p, n)
        case .regex(let r):
            let (p, n) = text(a, i, v, &scratch)
            let string = String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
            let regex = regexes[r]
            result = regex.firstMatch(in: string, range: NSRange(location: 0, length: string.utf16.count)) != nil
        case .ext(let list):
            let (p, n) = v.key(i)
            var found = false
            for suffix in list where n > suffix.count {
                if memcmp(p + (n - suffix.count), suffix.baseAddress, suffix.count) == 0 { found = true; break }
            }
            result = found && v.flags[i] & EntryFlag.directory == 0
        case .isFile:
            result = v.flags[i] & EntryFlag.directory == 0
        case .isFolder:
            result = v.flags[i] & EntryFlag.directory != 0
        case .size(let low, let high):
            let s = v.size[i]
            result = v.flags[i] & EntryFlag.directory == 0 && s >= low && s <= high
        case .modified(let low, let high):
            let m = v.mtime[i]
            result = m >= low && m <= high
        case .fuzzy(let f):
            let (p, n) = v.key(i)
            result = fuzzyRefs[f]._withUnsafeGuaranteedRef { $0.score(p, n, &scratch) } != nil
        case .external(let e):
            guard let bits = externalBits else { result = false; break }
            result = bits[e][i >> 6] & (UInt64(1) << UInt64(i & 63)) != 0
        }
        return result != a.negated
    }
}

/// 경로 비교용 작업 공간. 항목의 전체 경로 키("/users/me/문서/a.txt")를 필요할 때만 만든다.
struct PathScratch {
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity = 32 * 1024
    /// 유사 검색이 이름을 글자 단위로 풀어 둘 곳
    let scalars: UnsafeMutablePointer<UInt32>
    let scalarCapacity = 1024
    var length = 0
    var valid = false
    private var chain: [Int32] = []

    init() {
        buffer = .allocate(capacity: capacity)
        scalars = .allocate(capacity: scalarCapacity)
        chain.reserveCapacity(64)
    }

    func free() {
        buffer.deallocate()
        scalars.deallocate()
    }

    mutating func build(_ i: Int, _ v: IndexView) {
        chain.removeAll(keepingCapacity: true)
        var current = Int32(i)
        while current > 0 {
            chain.append(current)
            current = v.parent[Int(current)]
        }
        length = 0
        for node in chain.reversed() {
            let (p, n) = v.key(Int(node))
            guard length + n + 1 <= capacity else { break }
            buffer[length] = 0x2F
            (buffer + length + 1).update(from: p, count: n)
            length += n + 1
        }
        valid = true
    }
}

enum Wildcard {
    /// * 와 ? 를 지원하는 전체 일치. ? 는 UTF-8 글자 하나에 해당한다.
    static func match(_ pattern: UnsafeBufferPointer<UInt8>, _ text: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        let star = UInt8(ascii: "*"), question = UInt8(ascii: "?")
        var p = 0, t = 0
        var starP = -1, starT = 0
        while t < length {
            if p < pattern.count && pattern[p] == question {
                t += 1
                while t < length && text[t] & 0xC0 == 0x80 { t += 1 }
                p += 1
            } else if p < pattern.count && pattern[p] == star {
                starP = p
                starT = t
                p += 1
            } else if p < pattern.count && pattern[p] == text[t] {
                p += 1
                t += 1
            } else if starP >= 0 {
                p = starP + 1
                starT += 1
                t = starT
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == star { p += 1 }
        return p == pattern.count
    }
}

// MARK: - 해석

struct QueryParser {
    let now: Date
    var owned: [UnsafeMutableRawPointer] = []
    var regexes: [NSRegularExpression] = []
    var fuzzies: [FuzzyMatcher] = []
    var externalTerms: [ExternalTerm] = []
    /// 지금 해석하는 검색어의 일반 낱말을 모두 유사 검색으로 볼지
    var fuzzyAll = false

    init(now: Date) { self.now = now }

    mutating func parse(_ segments: [(String, Bool)]) throws -> CompiledQuery {
        var clauses: [[CompiledQuery.Alternative]] = []
        for (text, fuzzy) in segments {
            fuzzyAll = fuzzy
            try parseSegment(text, into: &clauses)
        }
        return CompiledQuery(clauses: clauses, regexes: regexes, fuzzies: fuzzies, externalTerms: externalTerms, owned: owned)
    }

    mutating func parseSegment(_ text: String, into clauses: inout [[CompiledQuery.Alternative]]) throws {
        for token in Self.split(text, separators: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            var alternatives: [CompiledQuery.Alternative] = []
            var extraClauses: [[CompiledQuery.Alternative]] = []
            let parts = Self.split(token, separators: { $0 == "|" })
            for part in parts {
                try alternatives.append(contentsOf: parseAlternative(part, single: parts.count == 1, extra: &extraClauses))
            }
            if !alternatives.isEmpty { clauses.append(alternatives) }
            clauses.append(contentsOf: extraClauses)
        }
    }

    /// 따옴표 밖의 구분자로 나눈다(따옴표는 그대로 남긴다).
    static func split(_ text: String, separators: (Character) -> Bool) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); current.append(ch); continue }
            if !quoted && separators(ch) {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func unquote(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "")
    }

    mutating func bytes(_ array: [UInt8]) -> UnsafeBufferPointer<UInt8> {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(array.count, 1))
        pointer.initialize(from: array, count: array.count)
        owned.append(UnsafeMutableRawPointer(pointer))
        return UnsafeBufferPointer(start: pointer, count: array.count)
    }

    mutating func parseAlternative(_ raw: String, single: Bool, extra: inout [[CompiledQuery.Alternative]]) throws -> [CompiledQuery.Alternative] {
        var text = raw
        var negated = false
        while text.hasPrefix("!") {
            negated.toggle()
            text.removeFirst()
        }
        // ~낱말 = 이 낱말만 유사 검색 (~/문서 같은 경로는 제외)
        var fuzzyTerm = fuzzyAll
        if text.hasPrefix("~") && !text.contains("/") {
            fuzzyTerm = true
            text.removeFirst()
        }
        guard !text.isEmpty else { return [] }

        var modifier = ""
        var value = text
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("\"") {
            let candidate = text[..<colon].lowercased()
            if Self.modifiers.contains(candidate) || Self.aliases[candidate] != nil {
                modifier = Self.aliases[candidate] ?? candidate
                value = String(text[text.index(after: colon)...])
            }
        }
        value = Self.unquote(value)

        func make(_ predicate: CompiledQuery.Predicate, inPath: Bool = false) -> CompiledQuery.Alternative {
            CompiledQuery.Alternative(predicate: predicate, negated: negated, inPath: inPath)
        }

        switch modifier {
        case "":
            return try plainTerm(value, forcePath: false, negated: negated, fuzzy: fuzzyTerm)
        case "fuzzy":
            return try plainTerm(value, forcePath: false, negated: negated, fuzzy: true)
        case "path":
            return try plainTerm(value, forcePath: true, negated: negated, fuzzy: false)
        case "regex":
            guard !value.isEmpty else { return [] }
            do {
                let regex = try NSRegularExpression(pattern: value, options: [.caseInsensitive])
                regexes.append(regex)
                return [make(.regex(regexes.count - 1), inPath: value.contains("/"))]
            } catch {
                throw QueryError(description: "정규식이 올바르지 않아요: \(value)")
            }
        case "ext", "kind":
            var names = value.split(whereSeparator: { $0 == ";" || $0 == "," }).map(String.init)
            if modifier == "kind" {
                let kind = value.lowercased()
                if ["folder", "dir", "폴더"].contains(kind) { return [make(.isFolder)] }
                guard let list = Self.kinds.first(where: { $0.names.contains(kind) })?.extensions else {
                    throw QueryError(description: "종류를 모르겠어요: kind:\(value) (image, video, audio, doc, archive, code, folder)")
                }
                names = list
            }
            let exts = names.map { TextKey.key("." + $0.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
            guard !exts.isEmpty else { return [] }
            let list = UnsafeMutablePointer<UnsafeBufferPointer<UInt8>>.allocate(capacity: exts.count)
            owned.append(UnsafeMutableRawPointer(list))
            for (i, e) in exts.enumerated() { (list + i).initialize(to: bytes(e)) }
            return [make(.ext(UnsafeBufferPointer(start: list, count: exts.count)))]
        case "file", "folder", "dir":
            let kind = make(modifier == "file" ? .isFile : .isFolder)
            if !value.isEmpty {
                if single {
                    extra.append(try plainTerm(value, forcePath: false, negated: false, fuzzy: fuzzyTerm))
                }
            }
            return [kind]
        case "size":
            guard let range = Self.parseSize(value) else { throw QueryError(description: "크기 조건을 읽지 못했어요: size:\(value)") }
            return [make(.size(range.0, range.1))]
        case "dm", "datemodified":
            guard let range = Self.parseDate(value, now: now) else { throw QueryError(description: "날짜 조건을 읽지 못했어요: dm:\(value)") }
            return [make(.modified(range.0, range.1))]
        case "content", "tag", "author", "spotlight":
            guard !value.isEmpty else { return [] }
            if modifier == "spotlight" && !ExternalSearcher.isValidSpotlightQuery(value) {
                throw QueryError(description: "Spotlight 질의를 읽지 못했어요: \(value)")
            }
            externalTerms.append(ExternalTerm(kind: ExternalTerm.Kind(rawValue: modifier)!, value: value))
            return [make(.external(externalTerms.count - 1))]
        case "taken":
            guard let range = Self.parseDate(value, now: now) else { throw QueryError(description: "날짜 조건을 읽지 못했어요: taken:\(value)") }
            externalTerms.append(ExternalTerm(kind: .taken, value: value, low: range.0, high: range.1))
            return [make(.external(externalTerms.count - 1))]
        default:
            return []
        }
    }

    static let modifiers: Set<String> = ["path", "regex", "ext", "file", "folder", "dir", "size", "dm", "datemodified", "fuzzy",
                                         "kind", "content", "tag", "author", "taken", "spotlight"]
    /// 한글로도 쓸 수 있는 이름
    static let aliases: [String: String] = ["내용": "content", "태그": "tag", "작성자": "author", "촬영": "taken", "종류": "kind"]

    static let kinds: [(names: Set<String>, extensions: [String])] = [
        (["image", "picture", "photo", "사진", "이미지", "그림"],
         ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "dng", "raw", "cr2", "cr3", "nef", "arw", "psd"]),
        (["video", "movie", "동영상", "영상"], ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "mpg", "mpeg", "3gp"]),
        (["audio", "music", "sound", "음악", "소리", "오디오"], ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "ogg", "wma"]),
        (["doc", "document", "문서"],
         ["hwp", "hwpx", "doc", "docx", "pdf", "ppt", "pptx", "xls", "xlsx", "key", "pages", "numbers", "txt", "md", "rtf", "odt", "ods", "odp", "csv"]),
        (["archive", "zip", "압축"], ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "dmg", "alz", "egg"]),
        (["code", "source", "코드"],
         ["swift", "py", "js", "ts", "tsx", "jsx", "java", "c", "cpp", "h", "m", "kt", "go", "rs", "rb", "php", "html", "css", "json", "yml", "yaml", "sh"]),
    ]

    mutating func plainTerm(_ value: String, forcePath: Bool, negated: Bool, fuzzy: Bool) throws -> [CompiledQuery.Alternative] {
        guard !value.isEmpty else { return [] }
        let key = TextKey.key(value)
        let inPath = forcePath || value.contains("/")
        let isWildcard = value.contains("*") || value.contains("?")
        // 유사 검색이거나 초성(ㄱ~ㅎ)이 섞인 낱말은 유사 일치기로 찾는다.
        let hasConsonant = value.unicodeScalars.contains { FuzzyMatcher.isConsonant($0.value) }
        if !inPath && !isWildcard && (fuzzy || hasConsonant) {
            fuzzies.append(FuzzyMatcher(key: key, tolerant: fuzzy))
            return [CompiledQuery.Alternative(predicate: .fuzzy(fuzzies.count - 1), negated: negated, inPath: false)]
        }
        let predicate: CompiledQuery.Predicate = isWildcard ? .wildcard(bytes(isWildcard && inPath && !value.hasPrefix("/") && !value.hasPrefix("*") ? TextKey.key("*" + value) : key)) : .substring(bytes(key))
        return [CompiledQuery.Alternative(predicate: predicate, negated: negated, inPath: inPath)]
    }

    // MARK: 크기

    static func parseSize(_ text: String) -> (Int64, Int64)? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t == "empty" { return (0, 0) }
        if let dots = t.range(of: "..") {
            guard let low = parseBytes(String(t[..<dots.lowerBound])), let high = parseBytes(String(t[dots.upperBound...])) else { return nil }
            return (low, high)
        }
        for (op, apply) in [(">=", { (n: Int64) in (n, Int64.max) }), ("<=", { (n: Int64) in (0, n) }),
                            (">", { (n: Int64) in (n + 1, Int64.max) }), ("<", { (n: Int64) in (0, max(0, n - 1)) }),
                            ("=", { (n: Int64) in (n, n) })] as [(String, (Int64) -> (Int64, Int64))] where t.hasPrefix(op) {
            guard let n = parseBytes(String(t.dropFirst(op.count))) else { return nil }
            return apply(n)
        }
        guard let n = parseBytes(t) else { return nil }
        return (n, n)
    }

    static func parseBytes(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let digits = t.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits) else { return nil }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "k", "kb": multiplier = 1024
        case "m", "mb": multiplier = 1024 * 1024
        case "g", "gb": multiplier = 1024 * 1024 * 1024
        case "t", "tb": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(number * multiplier)
    }

    // MARK: 날짜

    static func parseDate(_ text: String, now: Date) -> (Int64, Int64)? {
        let calendar = Calendar.current
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let today = calendar.startOfDay(for: now)
        func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) }
        func start(of component: Calendar.Component) -> Date {
            calendar.dateInterval(of: component, for: now)?.start ?? today
        }
        switch t {
        case "today": return (seconds(today), Int64.max)
        case "yesterday":
            let y = calendar.date(byAdding: .day, value: -1, to: today)!
            return (seconds(y), seconds(today) - 1)
        case "thisweek": return (seconds(start(of: .weekOfYear)), Int64.max)
        case "thismonth": return (seconds(start(of: .month)), Int64.max)
        case "thisyear": return (seconds(start(of: .year)), Int64.max)
        default: break
        }
        // 7d, 24h, 2w 처럼 "최근 N일/시간/주"
        if let last = t.last, "hdwmy".contains(last), let n = Int(t.dropLast()) {
            let unit: Calendar.Component = ["h": .hour, "d": .day, "w": .weekOfYear, "m": .month, "y": .year][last]!
            let from = calendar.date(byAdding: unit, value: -n, to: now)!
            return (seconds(from), Int64.max)
        }
        /// 날짜와 그 날짜가 덮는 범위(일·월·년)
        func period(_ s: String) -> (Date, Calendar.Component)? {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            for (format, unit) in [("yyyy-MM-dd", Calendar.Component.day), ("yyyy/MM/dd", .day), ("yyyyMMdd", .day), ("yyyy-MM", .month), ("yyyy", .year)] {
                f.dateFormat = format
                if let d = f.date(from: s) { return (d, unit) }
            }
            return nil
        }
        func day(_ s: String) -> Date? {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyyMMdd", "yyyy-MM", "yyyy"] {
                f.dateFormat = format
                if let d = f.date(from: s) { return d }
            }
            return nil
        }
        /// 2026-05 → 5월 말, 2026 → 12월 31일 끝까지
        func end(_ s: String) -> Int64? {
            guard let (d, unit) = period(s) else { return nil }
            return seconds(calendar.date(byAdding: unit, value: 1, to: d)!) - 1
        }
        if let dots = t.range(of: "..") {
            guard let a = day(String(t[..<dots.lowerBound])), let b = end(String(t[dots.upperBound...])) else { return nil }
            return (seconds(a), b)
        }
        for op in [">=", "<=", ">", "<", "="] where t.hasPrefix(op) {
            let rest = String(t.dropFirst(op.count))
            guard let d = day(rest), let last = end(rest) else { return nil }
            switch op {
            case ">=": return (seconds(d), Int64.max)
            case ">": return (last + 1, Int64.max)
            case "<=": return (Int64.min, last)
            case "<": return (Int64.min, seconds(d) - 1)
            default: return (seconds(d), last)
            }
        }
        if let d = day(t), let last = end(t) { return (seconds(d), last) }
        return nil
    }
}
