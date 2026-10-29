import Foundation

public enum SortKey: String, Sendable {
    case name, path, size, modified
}

public struct SearchOutcome: Sendable {
    public let ids: [Int32]
    public let epoch: UInt64
    public let generation: UInt64
    public let elapsed: TimeInterval
    public let cancelled: Bool
}

extension FileIndex {
    /// 모든 CPU 코어로 나눠 훑어 조건에 맞는 id를 정렬해 돌려준다.
    /// external은 query.externalTerms 순서대로, 각 조건에 맞는 경로 목록들이다.
    public func search(_ query: CompiledQuery, sort: SortKey = .name, ascending: Bool = true, cancel: CancelToken? = nil,
                       external: [[ExternalMatch]] = []) -> SearchOutcome {
        let started = Date()
        return lock.read {
            let v = view()
            if !query.externalTerms.isEmpty {
                let words = (v.count + 63) / 64
                let bits = UnsafeMutablePointer<UnsafeMutablePointer<UInt64>>.allocate(capacity: query.externalTerms.count)
                for t in 0..<query.externalTerms.count {
                    bits[t] = .allocate(capacity: words)
                    bits[t].initialize(repeating: 0, count: words)
                    if t < external.count {
                        for match in external[t] {
                            for id in match.ids(epoch: layoutEpoch, resolve: idsLocked) {
                                bits[t][Int(id) >> 6] |= UInt64(1) << UInt64(Int(id) & 63)
                            }
                        }
                    }
                }
                query.externalBits = bits
            }
            defer {
                if let bits = query.externalBits {
                    for t in 0..<query.externalTerms.count { bits[t].deallocate() }
                    bits.deallocate()
                    query.externalBits = nil
                }
            }
            var ids: [Int32]
            var cancelled = false
            if sort == .name && nameOrderCoverage > 1 {
                let covered = nameOrder.withUnsafeBufferPointer { order in
                    Self.parallelFilter(count: order.count, ids: order.baseAddress, query: query, view: v, cancel: cancel, cancelled: &cancelled)
                }
                var tail: [Int32] = []
                if nameOrderCoverage < v.count && !cancelled {
                    tail = Self.parallelFilter(count: v.count - nameOrderCoverage, offset: nameOrderCoverage, ids: nil,
                                               query: query, view: v, cancel: cancel, cancelled: &cancelled)
                    tail.sort { v.keyLess($0, $1) }
                }
                ids = Self.merge(covered, tail, v)
            } else {
                ids = Self.parallelFilter(count: v.count - 1, offset: 1, ids: nil, query: query, view: v, cancel: cancel, cancelled: &cancelled)
                if !cancelled { sortIds(&ids, by: sort, v) }
            }
            if query.ranksByRelevance && sort == .name && ascending && !cancelled {
                Self.rankByRelevance(&ids, query: query, view: v)
            }
            if !ascending { ids.reverse() }
            return SearchOutcome(ids: cancelled ? [] : ids, epoch: layoutEpoch, generation: generation,
                                 elapsed: Date().timeIntervalSince(started), cancelled: cancelled)
        }
    }

    /// ids가 있으면 ids[0..<count]를, 없으면 offset..<offset+count 범위의 id를 검사한다.
    /// 조각마다 결과를 따로 모은 뒤 순서대로 이어 붙이므로 입력 순서가 유지된다.
    static func parallelFilter(count: Int, offset: Int = 0, ids: UnsafePointer<Int32>?, query: CompiledQuery,
                               view v: IndexView, cancel: CancelToken?, cancelled: inout Bool) -> [Int32] {
        guard count > 0 else { return [] }
        let chunkSize = max(16_384, count / (ProcessInfo.processInfo.activeProcessorCount * 4))
        let chunks = (count + chunkSize - 1) / chunkSize
        let results = UnsafeMutablePointer<[Int32]>.allocate(capacity: chunks)
        results.initialize(repeating: [], count: chunks)
        defer {
            results.deinitialize(count: chunks)
            results.deallocate()
        }
        let empty = query.isEmpty
        let flags = v.flags
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let low = chunk * chunkSize
            let high = min(count, low + chunkSize)
            var local: [Int32] = []
            var scratch = PathScratch()
            defer { scratch.free() }
            var position = low
            while position < high {
                if cancel?.isCancelled == true { return }
                let stop = min(high, position + 8192)
                while position < stop {
                    let id = ids.map { Int($0[position]) } ?? (offset + position)
                    if flags[id] & EntryFlag.deleted == 0 && (empty || query.matches(id, v, &scratch)) {
                        local.append(Int32(id))
                    }
                    position += 1
                }
            }
            results[chunk] = local
        }
        if cancel?.isCancelled == true {
            cancelled = true
            return []
        }
        var total = 0
        for c in 0..<chunks { total += results[c].count }
        var out: [Int32] = []
        out.reserveCapacity(total)
        for c in 0..<chunks { out.append(contentsOf: results[c]) }
        return out
    }

    /// 유사 검색 결과를 비슷한 순서(점수가 같으면 이름순)로 다시 늘어놓는다.
    static func rankByRelevance(_ ids: inout [Int32], query: CompiledQuery, view v: IndexView) {
        let count = ids.count
        guard count > 1 else { return }
        var scores = [Int32](repeating: 0, count: count)
        let chunkSize = 8192
        let chunks = (count + chunkSize - 1) / chunkSize
        ids.withUnsafeBufferPointer { idBuffer in
            scores.withUnsafeMutableBufferPointer { scoreBuffer in
                let idPointer = idBuffer.baseAddress!
                let scorePointer = scoreBuffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    var scratch = PathScratch()
                    defer { scratch.free() }
                    for i in (chunk * chunkSize)..<min(count, (chunk + 1) * chunkSize) {
                        scorePointer[i] = Int32(query.relevance(Int(idPointer[i]), v, &scratch))
                    }
                }
            }
        }
        // (점수, 이름 길이) 순으로 계수 정렬한다. 점수가 같으면 이름이 짧은 쪽(검색어와 더 가까운 쪽),
        // 그다음은 원래의 이름순(안정 정렬). 결과가 수백만 개여도 비교 정렬보다 훨씬 빠르다.
        let lengthBuckets = 256
        let bucketCount = 1024 * lengthBuckets
        var starts = [Int32](repeating: 0, count: bucketCount + 1)
        var keys = [Int32](repeating: 0, count: count)
        for i in 0..<count {
            let key = Int(min(scores[i], 1023)) * lengthBuckets + min(Int(v.keyLen[Int(ids[i])]), lengthBuckets - 1)
            keys[i] = Int32(key)
            starts[key + 1] += 1
        }
        for b in 0..<bucketCount { starts[b + 1] += starts[b] }
        var sorted = [Int32](repeating: 0, count: count)
        for i in 0..<count {
            let key = Int(keys[i])
            sorted[Int(starts[key])] = ids[i]
            starts[key] += 1
        }
        ids = sorted
    }

    /// 경로 목록을 id로 바꾼다. 같은 폴더의 파일이 많으므로 폴더 id와 폴더별 이름표를 만들어 두고 쓴다.
    func idsLocked(paths: [String]) -> [Int32] {
        var directories: [Substring: Int32] = ["": 0]
        /// 폴더 id → (이름 → 항목 id). 정규화한 키는 앞에 \0을 붙여 같은 표에 넣는다.
        var children: [Int32: [String: Int32]] = [:]
        func child(_ parent: Int32, _ name: Substring) -> Int32? {
            if children[parent] == nil {
                var map: [String: Int32] = [:]
                forEachChildLocked(parent) { c in
                    let i = Int(c)
                    let exact = String(decoding: UnsafeBufferPointer(start: nameBytes.pointer + Int(nameStart[i]), count: Int(nameLen[i])), as: UTF8.self)
                    let key = "\0" + String(decoding: UnsafeBufferPointer(start: nameBytes.pointer + Int(keyStart[i]), count: Int(keyLen[i])), as: UTF8.self)
                    if map[exact] == nil { map[exact] = c }
                    if map[key] == nil { map[key] = c }
                }
                children[parent] = map
            }
            let map = children[parent]!
            if let id = map[String(name)] { return id }
            return map["\0" + String(decoding: TextKey.key(String(name)), as: UTF8.self)]
        }
        func resolve(_ path: Substring) -> Int32? {
            if let known = directories[path] { return known }
            guard let slash = path.lastIndex(of: "/") else { return nil }
            guard let parent = resolve(path[..<slash]), let id = child(parent, path[path.index(after: slash)...]) else { return nil }
            directories[path] = id
            return id
        }
        var ids: [Int32] = []
        ids.reserveCapacity(paths.count)
        for path in paths {
            let full = Substring(path)
            guard let slash = full.lastIndex(of: "/") else { continue }
            if let parent = resolve(full[..<slash]), let id = child(parent, full[full.index(after: slash)...]) {
                ids.append(id)
            }
        }
        return ids
    }

    func sortIds(_ ids: inout [Int32], by sort: SortKey, _ v: IndexView) {
        switch sort {
        case .name:
            ids.sort { v.keyLess($0, $1) }
        case .size:
            ids.sort { a, b in
                let sa = v.size[Int(a)], sb = v.size[Int(b)]
                return sa != sb ? sa < sb : v.keyLess(a, b)
            }
        case .modified:
            ids.sort { a, b in
                let ma = v.mtime[Int(a)], mb = v.mtime[Int(b)]
                return ma != mb ? ma < mb : v.keyLess(a, b)
            }
        case .path:
            // 결과에 나온 부모 디렉터리들만 경로 키로 정렬해 순위를 매기고, (부모 순위, 이름)으로 정렬한다.
            var parents = Set<Int32>()
            for id in ids { parents.insert(v.parent[Int(id)]) }
            var scratch = PathScratch()
            defer { scratch.free() }
            var keyed: [(Int32, [UInt8])] = []
            keyed.reserveCapacity(parents.count)
            for p in parents {
                scratch.build(Int(p), v)
                keyed.append((p, Array(UnsafeBufferPointer(start: scratch.buffer, count: scratch.length))))
            }
            keyed.sort { $0.1.lexicographicallyPrecedes($1.1) }
            var rank = [Int32: Int32](minimumCapacity: keyed.count)
            for (i, entry) in keyed.enumerated() { rank[entry.0] = Int32(i) }
            let ranks = ids.map { rank[v.parent[Int($0)]]! }
            var order = Array(0..<ids.count)
            order.sort { a, b in ranks[a] != ranks[b] ? ranks[a] < ranks[b] : v.keyLess(ids[a], ids[b]) }
            ids = order.map { ids[$0] }
        }
    }
}
