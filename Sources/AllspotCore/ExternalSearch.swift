import CoreServices
import Foundation

/// 파일 이름 색인 밖에서 답을 구해 오는 검색 조건(내용·태그·작성자·촬영일·Spotlight 질의).
/// 검색할 때 먼저 경로 목록을 구하고, 이름 색인에서는 그 경로에 든 항목만 맞는 것으로 본다.
public struct ExternalTerm: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case content, tag, author, taken, spotlight
    }

    public let kind: Kind
    public let value: String
    /// 내용·작성자 비교용으로 정규화한 바이트
    let key: [UInt8]
    let low: Int64
    let high: Int64

    init(kind: Kind, value: String, low: Int64 = 0, high: Int64 = 0) {
        self.kind = kind
        self.value = value
        key = TextKey.contentKey(value)
        self.low = low
        self.high = high
    }

    /// Spotlight에 넘길 질의
    var spotlightQuery: String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch kind {
        case .content: return "kMDItemTextContent == \"*\(escaped)*\"cd"
        case .tag: return "kMDItemUserTags == \"*\(escaped)*\"cd"
        case .author: return "kMDItemAuthors == \"*\(escaped)*\"cd"
        case .spotlight: return value
        case .taken:
            var parts = ["(kMDItemContentTypeTree == \"public.image\" || kMDItemContentTypeTree == \"public.movie\")"]
            if low > Int64.min { parts.append("kMDItemContentCreationDate >= \(Self.time(low))") }
            if high < Int64.max { parts.append("kMDItemContentCreationDate <= \(Self.time(high))") }
            return parts.joined(separator: " && ")
        }
    }

    private static func time(_ seconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "$time.iso(\(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))))"
    }
}

/// 밖에서 구해 온 경로 목록. 이름 색인 id로 바꾼 결과를 색인 배치(layoutEpoch)가 같은 동안 기억해 둔다.
public final class ExternalMatch: @unchecked Sendable {
    public let paths: [String]
    private let lock = NSLock()
    private var cachedIds: [Int32]?
    private var cachedEpoch: UInt64 = 0

    public init(paths: [String]) {
        self.paths = paths
    }

    func ids(epoch: UInt64, resolve: ([String]) -> [Int32]) -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIds, cachedEpoch == epoch { return cachedIds }
        let ids = resolve(paths)
        cachedIds = ids
        cachedEpoch = epoch
        return ids
    }
}

/// 조건마다 맞는 경로를 구한다. 한글 문서는 자체 내용 색인에서, 나머지는 Spotlight 색인에서 찾는다.
public final class ExternalSearcher: @unchecked Sendable {
    private let content: ContentIndex?
    private let lock = NSLock()
    /// Spotlight 질의는 수백 ms까지 걸리므로 같은 조건은 잠시 기억해 둔다(글자를 더 칠 때마다 다시 묻지 않게).
    private var cache: [ExternalTerm: (at: Date, match: ExternalMatch)] = [:]
    private let cacheLifetime: TimeInterval = 30

    public init(content: ContentIndex?) {
        self.content = content
    }

    /// 조건 하나에 맞는 경로들(Spotlight 몫과 자체 내용 색인 몫). spotlight가 거짓이면 자체 색인만 본다.
    public func matches(for term: ExternalTerm, cancel: CancelToken?, spotlight: Bool = true) -> [ExternalMatch] {
        var result: [ExternalMatch] = []
        if spotlight, let found = spotlightMatch(term, cancel: cancel) { result.append(found) }
        if let content {
            switch term.kind {
            case .content: result.append(ExternalMatch(paths: content.search(term.key, cancel: cancel)))
            case .author: result.append(ExternalMatch(paths: content.search(term.key, inAuthor: true, cancel: cancel)))
            default: break
            }
        }
        return result
    }

    /// 자체 내용 색인만으로 답할 수 있는 조건인지(내용·작성자)
    public static func isLocal(_ term: ExternalTerm) -> Bool {
        term.kind == .content || term.kind == .author
    }

    /// Spotlight 답을 기억해 둔 조건인지(그러면 바로 답할 수 있다)
    public func hasCachedSpotlight(_ term: ExternalTerm) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = cache[term] else { return false }
        return Date().timeIntervalSince(hit.at) < cacheLifetime
    }

    private func spotlightMatch(_ term: ExternalTerm, cancel: CancelToken?) -> ExternalMatch? {
        lock.lock()
        if let hit = cache[term], Date().timeIntervalSince(hit.at) < cacheLifetime {
            lock.unlock()
            return hit.match
        }
        lock.unlock()
        guard let paths = Self.spotlight(term.spotlightQuery, cancel: cancel) else { return nil }
        let match = ExternalMatch(paths: paths)
        lock.lock()
        if cache.count > 32 { cache.removeAll() }
        cache[term] = (Date(), match)
        lock.unlock()
        return match
    }

    /// Spotlight 질의 하나가 돌려줄 최대 경로 수(넓은 질의가 메모리·시간을 다 쓰지 않게)
    static let maxSpotlightResults = 200_000

    /// Spotlight 질의를 끝까지 돌려 경로를 모은다. 질의가 틀렸거나 취소되면 nil.
    static func spotlight(_ query: String, cancel: CancelToken?) -> [String]? {
        guard let q = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return nil }
        MDQuerySetMaxCount(q, maxSpotlightResults)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        let count = MDQueryGetResultCount(q)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for i in 0..<count {
            if i % 4096 == 0 && cancel?.isCancelled == true { return nil }
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
        }
        return paths
    }

    /// 사용자가 직접 쓴 Spotlight 질의가 올바른지
    static func isValidSpotlightQuery(_ query: String) -> Bool {
        MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) != nil
    }
}
