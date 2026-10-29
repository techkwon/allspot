import Foundation

public enum EntryFlag {
    public static let directory: UInt8 = 1 << 0
    public static let deleted: UInt8 = 1 << 1
    public static let symlink: UInt8 = 1 << 2
}

public struct EntryInfo: Sendable {
    public let id: Int32
    public let name: String
    public let parentPath: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let modified: Date

    public var fullPath: String {
        parentPath == "/" ? "/" + name : parentPath + "/" + name
    }
}

/// 검색 루프가 쓰는 색인 포인터 묶음. 읽기 잠금을 잡은 동안에만 유효하다.
struct IndexView {
    let count: Int
    let parent: UnsafeMutablePointer<Int32>
    let keyStart: UnsafeMutablePointer<UInt32>
    let keyLen: UnsafeMutablePointer<UInt16>
    let size: UnsafeMutablePointer<Int64>
    let mtime: UnsafeMutablePointer<Int64>
    let flags: UnsafeMutablePointer<UInt8>
    let keyBytes: UnsafeMutablePointer<UInt8>

    @inline(__always) func key(_ i: Int) -> (UnsafeMutablePointer<UInt8>, Int) {
        (keyBytes + Int(keyStart[i]), Int(keyLen[i]))
    }

    /// 이름 키 순서 비교(같으면 id 순).
    @inline(__always) func keyLess(_ a: Int32, _ b: Int32) -> Bool {
        let (pa, la) = key(Int(a))
        let (pb, lb) = key(Int(b))
        let c = memcmp(pa, pb, min(la, lb))
        if c != 0 { return c < 0 }
        if la != lb { return la < lb }
        return a < b
    }
}

/// 디스크 전체의 파일 이름 색인.
/// 항목을 구조체 배열이 아니라 필드별 배열로 담아(struct of arrays) 수백만 개도 적은 메모리로 다룬다.
/// id 0은 루트("/")다. 지운 항목은 바로 빼지 않고 표시만 해 두었다가 압축할 때 정리한다.
public final class FileIndex: @unchecked Sendable {
    let lock = RWLock()

    var parent = RawArray<Int32>()
    var nameStart = RawArray<UInt32>()
    var nameLen = RawArray<UInt16>()
    var keyStart = RawArray<UInt32>()
    var keyLen = RawArray<UInt16>()
    var size = RawArray<Int64>()
    var mtime = RawArray<Int64>()
    var flags = RawArray<UInt8>()
    /// 디렉터리의 자식은 한 번에 이어 붙이므로 시작 id와 개수만으로 찾는다. 나중에 늘어난 자식은 extraChildren에 둔다.
    var childStart = RawArray<Int32>()
    var childCount = RawArray<Int32>()
    var extraChildren: [Int32: [Int32]] = [:]
    /// 이름과 (이름과 다를 때만) 검색 키를 담는 바이트 더미.
    var nameBytes = RawArray<UInt8>(capacity: 1 << 20)

    /// 이름 키 순으로 미리 정렬해 둔 id. nameOrderCoverage 미만의 id만 담고 있고, 그 뒤에 추가된 항목은 검색 때 따로 정렬해 합친다.
    var nameOrder: [Int32] = []
    var nameOrderCoverage = 0

    /// 내용이 바뀔 때마다 증가한다.
    public internal(set) var generation: UInt64 = 0
    /// id 체계가 통째로 바뀔 때(재구축, 압축) 증가한다. 이 값이 다르면 예전 검색 결과의 id는 쓸 수 없다.
    public internal(set) var layoutEpoch: UInt64 = 0
    var liveCountStorage = 0
    var deletedCount = 0
    /// 예전 저장 형식에서 읽었으면 참(곧 새 형식으로 다시 저장해야 메모리를 덜 쓴다)
    public internal(set) var loadedLegacyFormat = false

    public init() {
        resetLocked()
    }

    public var liveCount: Int { lock.read { liveCountStorage } }
    public var currentEpoch: UInt64 { lock.read { layoutEpoch } }

    // MARK: - 만들기와 비우기

    func resetLocked() {
        parent = RawArray(); nameStart = RawArray(); nameLen = RawArray()
        keyStart = RawArray(); keyLen = RawArray(); size = RawArray(); mtime = RawArray()
        flags = RawArray(); childStart = RawArray(); childCount = RawArray()
        nameBytes = RawArray(capacity: 1 << 20)
        extraChildren = [:]
        nameOrder = []; nameOrderCoverage = 0
        liveCountStorage = 0; deletedCount = 0
        layoutEpoch &+= 1; generation &+= 1
        // 루트
        parent.append(-1); nameStart.append(0); nameLen.append(0); keyStart.append(0); keyLen.append(0)
        size.append(0); mtime.append(0); flags.append(EntryFlag.directory)
        childStart.append(-1); childCount.append(0)
    }

    public func reset() {
        lock.write { resetLocked() }
    }

    func view() -> IndexView {
        IndexView(count: parent.count, parent: parent.pointer, keyStart: keyStart.pointer, keyLen: keyLen.pointer,
                  size: size.pointer, mtime: mtime.pointer, flags: flags.pointer, keyBytes: nameBytes.pointer)
    }

    // MARK: - 추가와 삭제 (쓰기 잠금을 잡은 채 호출)

    /// dir 아래에 batch의 항목을 덧붙이고 첫 id를 돌려준다.
    @discardableResult
    func appendLocked(_ batch: EntryBatch, to dir: Int32) -> Int32 {
        let first = Int32(parent.count)
        let n = batch.count
        guard n > 0 else { return first }
        let total = parent.count + n
        for array in [parent, childStart, childCount] as [RawArray<Int32>] { array.reserve(total) }
        nameStart.reserve(total); nameLen.reserve(total); keyStart.reserve(total); keyLen.reserve(total)
        size.reserve(total); mtime.reserve(total); flags.reserve(total)

        nameBytes.reserve(nameBytes.count + batch.nameBytes.count + batch.keyBytes.count)
        batch.nameBytes.withUnsafeBufferPointer { names in
            batch.keyBytes.withUnsafeBufferPointer { keys in
                var previousName = 0
                var previousKey = 0
                for i in 0..<n {
                    let name = UnsafeBufferPointer(rebasing: names[previousName..<batch.nameEnds[i]])
                    let key = UnsafeBufferPointer(rebasing: keys[previousKey..<batch.keyEnds[i]])
                    previousName = batch.nameEnds[i]
                    previousKey = batch.keyEnds[i]
                    let start = UInt32(nameBytes.count)
                    nameBytes.append(contentsOf: name)
                    nameStart.append(start)
                    nameLen.append(UInt16(clamping: name.count))
                    // 이름이 이미 소문자 NFC면(대부분) 키는 이름 바이트를 같이 쓴다.
                    if key.elementsEqual(name) {
                        keyStart.append(start)
                    } else {
                        keyStart.append(UInt32(nameBytes.count))
                        nameBytes.append(contentsOf: key)
                    }
                    keyLen.append(UInt16(clamping: key.count))
                }
            }
        }
        for i in 0..<n {
            parent.append(dir)
            size.append(batch.sizes[i])
            mtime.append(batch.mtimes[i])
            flags.append(batch.flags[i])
            childStart.append(-1)
            childCount.append(0)
        }
        let d = Int(dir)
        if childStart[d] < 0 && extraChildren[dir] == nil {
            childStart[d] = first
            childCount[d] = Int32(n)
        } else {
            extraChildren[dir, default: []].append(contentsOf: first..<(first + Int32(n)))
        }
        liveCountStorage += n
        generation &+= 1
        return first
    }

    @inline(__always) func isLive(_ i: Int) -> Bool {
        flags[i] & EntryFlag.deleted == 0
    }

    func forEachChildLocked(_ dir: Int32, _ body: (Int32) -> Void) {
        let d = Int(dir)
        let start = childStart[d]
        if start >= 0 {
            for i in start..<(start + childCount[d]) where isLive(Int(i)) { body(i) }
        }
        if let extra = extraChildren[dir] {
            for i in extra where isLive(Int(i)) { body(i) }
        }
    }

    /// id(자신 포함 여부 선택)와 그 아래 전부를 지운 것으로 표시한다.
    func tombstoneLocked(_ id: Int32, includingSelf: Bool) {
        var stack: [Int32] = []
        if includingSelf {
            stack.append(id)
        } else {
            forEachChildLocked(id) { stack.append($0) }
            childStart[Int(id)] = -1
            childCount[Int(id)] = 0
            extraChildren[id] = nil
        }
        while let current = stack.popLast() {
            let c = Int(current)
            guard isLive(c) else { continue }
            if flags[c] & EntryFlag.directory != 0 {
                forEachChildLocked(current) { stack.append($0) }
                extraChildren[current] = nil
            }
            flags[c] |= EntryFlag.deleted
            liveCountStorage -= 1
            deletedCount += 1
        }
        generation &+= 1
    }

    // MARK: - 경로

    func nameLocked(_ i: Int) -> String {
        String(decoding: UnsafeBufferPointer(start: nameBytes.pointer + Int(nameStart[i]), count: Int(nameLen[i])), as: UTF8.self)
    }

    func pathLocked(_ id: Int32) -> String {
        if id == 0 { return "/" }
        var chain: [Int32] = []
        var current = id
        while current > 0 {
            chain.append(current)
            current = parent[Int(current)]
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(128)
        for node in chain.reversed() {
            bytes.append(0x2F)
            let i = Int(node)
            bytes.append(contentsOf: UnsafeBufferPointer(start: nameBytes.pointer + Int(nameStart[i]), count: Int(nameLen[i])))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func path(of id: Int32) -> String {
        lock.read { pathLocked(id) }
    }

    /// 경로로 항목을 찾는다. 대소문자·유니코드 정규화가 달라도 찾는다.
    func lookupLocked(_ path: String) -> Int32? {
        var current: Int32 = 0
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let wanted = Array(component.utf8)
            let wantedKey = TextKey.key(String(component))
            var exact: Int32?
            var loose: Int32?
            forEachChildLocked(current) { child in
                guard exact == nil else { return }
                let c = Int(child)
                let n = UnsafeBufferPointer(start: nameBytes.pointer + Int(nameStart[c]), count: Int(nameLen[c]))
                if n.elementsEqual(wanted) {
                    exact = child
                } else if loose == nil {
                    let k = UnsafeBufferPointer(start: nameBytes.pointer + Int(keyStart[c]), count: Int(keyLen[c]))
                    if k.elementsEqual(wantedKey) { loose = child }
                }
            }
            guard let next = exact ?? loose else { return nil }
            current = next
        }
        return current
    }

    /// 폴더 안 모든 파일 크기의 합(하위 폴더 포함). 색인 배치가 바뀌었으면 nil.
    public func folderSize(_ id: Int32, epoch: UInt64, cancel: CancelToken? = nil) -> Int64? {
        lock.read {
            guard epoch == layoutEpoch, Int(id) >= 0, Int(id) < parent.count, isLive(Int(id)) else { return nil }
            var total: Int64 = 0
            var stack: [Int32] = [id]
            var visited = 0
            while let dir = stack.popLast() {
                forEachChildLocked(dir) { child in
                    let f = flags[Int(child)]
                    if f & EntryFlag.directory != 0 {
                        if f & EntryFlag.symlink == 0 { stack.append(child) }
                    } else {
                        total &+= max(0, size[Int(child)])
                    }
                }
                visited += 1
                if visited % 4096 == 0 && cancel?.isCancelled == true { return nil }
            }
            return total
        }
    }

    public func lookup(_ path: String) -> Int32? {
        lock.read { lookupLocked(path) }
    }

    /// 경로의 중간 디렉터리를 (형제는 읽지 않고) 만들어 둔다. 루트가 "/"가 아닌 색인에 쓴다.
    func ensureDirectoryLocked(_ path: String) -> Int32 {
        var current: Int32 = 0
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            var found: Int32?
            let wanted = Array(component.utf8)
            forEachChildLocked(current) { child in
                let c = Int(child)
                let n = UnsafeBufferPointer(start: nameBytes.pointer + Int(nameStart[c]), count: Int(nameLen[c]))
                if found == nil && n.elementsEqual(wanted) { found = child }
            }
            if let found {
                current = found
            } else {
                var batch = EntryBatch()
                wanted.withUnsafeBufferPointer { batch.append(name: $0, flags: EntryFlag.directory, size: 0, mtime: 0) }
                current = appendLocked(batch, to: current)
            }
        }
        return current
    }

    // MARK: - 화면에 보여 줄 정보

    public func info(_ id: Int32, epoch: UInt64) -> EntryInfo? {
        lock.read {
            let i = Int(id)
            guard epoch == layoutEpoch, i > 0, i < parent.count, isLive(i) else { return nil }
            let f = flags[i]
            return EntryInfo(id: id, name: nameLocked(i), parentPath: pathLocked(parent[i]),
                             isDirectory: f & EntryFlag.directory != 0, isSymlink: f & EntryFlag.symlink != 0,
                             size: size[i], modified: Date(timeIntervalSince1970: TimeInterval(mtime[i])))
        }
    }

    // MARK: - 디렉터리 내용 갱신 (변경 감시용)

    /// 디렉터리를 다시 읽은 결과를 색인에 반영한다. 새로 생긴 하위 디렉터리(id, 경로)를 돌려주면 호출한 쪽이 그 안을 읽는다.
    func applyListing(_ batch: EntryBatch, to dir: Int32, dirPath: String) -> [(Int32, String)] {
        lock.write {
            var existing: [String: Int32] = [:]
            forEachChildLocked(dir) { existing[nameLocked(Int($0))] = $0 }

            var added = EntryBatch()
            var changed = false
            for i in 0..<batch.count {
                let name = batch.name(i)
                let newFlags = batch.flags[i]
                if let old = existing.removeValue(forKey: name) {
                    let o = Int(old)
                    let sameKind = (flags[o] & EntryFlag.directory) == (newFlags & EntryFlag.directory)
                        && (flags[o] & EntryFlag.symlink) == (newFlags & EntryFlag.symlink)
                    if sameKind {
                        if size[o] != batch.sizes[i] || mtime[o] != batch.mtimes[i] {
                            size[o] = batch.sizes[i]
                            mtime[o] = batch.mtimes[i]
                            changed = true
                        }
                        continue
                    }
                    tombstoneLocked(old, includingSelf: true)
                    changed = true
                }
                batch.nameBytes[batch.nameRange(i)].withUnsafeBufferPointer {
                    added.append(name: $0, flags: newFlags, size: batch.sizes[i], mtime: batch.mtimes[i])
                }
            }
            for (_, gone) in existing {
                tombstoneLocked(gone, includingSelf: true)
                changed = true
            }
            if let extra = extraChildren[dir] {
                let live = extra.filter { isLive(Int($0)) }
                extraChildren[dir] = live.isEmpty ? nil : live
            }
            var newDirectories: [(Int32, String)] = []
            if added.count > 0 {
                let first = appendLocked(added, to: dir)
                changed = true
                for i in 0..<added.count where added.flags[i] & EntryFlag.directory != 0 && added.flags[i] & EntryFlag.symlink == 0 {
                    let name = added.name(i)
                    newDirectories.append((first + Int32(i), dirPath == "/" ? "/" + name : dirPath + "/" + name))
                }
            }
            if changed { generation &+= 1 }
            return newDirectories
        }
    }

    // MARK: - 이름 순서

    /// 이름 순 정렬을 새로 만든다. 수백만 개면 1~2초 걸리므로 백그라운드에서 부른다.
    public func rebuildNameOrder() {
        let (order, coverage, epoch): ([Int32], Int, UInt64) = lock.read {
            let v = view()
            var ids: [Int32] = []
            ids.reserveCapacity(liveCountStorage)
            for i in 1..<v.count where v.flags[i] & EntryFlag.deleted == 0 { ids.append(Int32(i)) }
            ids.sort { v.keyLess($0, $1) }
            return (ids, v.count, layoutEpoch)
        }
        lock.write {
            guard epoch == layoutEpoch else { return }
            nameOrder = order
            nameOrderCoverage = coverage
        }
    }

    public var nameOrderLag: Int {
        lock.read { parent.count - nameOrderCoverage }
    }

    // MARK: - 압축

    public var tombstoneRatio: Double {
        lock.read { parent.count > 1 ? Double(deletedCount) / Double(parent.count) : 0 }
    }

    /// 지운 항목을 빼고, 디렉터리마다 자식이 이어지도록 너비 우선 순서로 다시 깐다.
    func compactLocked() {
        let oldCount = parent.count
        var newId = [Int32](repeating: -1, count: oldCount)
        var order: [Int32] = [0]
        order.reserveCapacity(liveCountStorage + 1)
        newId[0] = 0
        var newChildStart: [Int32] = [-1]
        var newChildCount: [Int32] = [0]
        newChildStart.reserveCapacity(liveCountStorage + 1)
        newChildCount.reserveCapacity(liveCountStorage + 1)
        var q = 0
        while q < order.count {
            let oldDir = order[q]
            let start = Int32(order.count)
            var n: Int32 = 0
            if flags[Int(oldDir)] & EntryFlag.directory != 0 {
                forEachChildLocked(oldDir) { child in
                    newId[Int(child)] = Int32(order.count)
                    order.append(child)
                    newChildStart.append(-1)
                    newChildCount.append(0)
                    n += 1
                }
            }
            if n > 0 {
                newChildStart[q] = start
                newChildCount[q] = n
            }
            q += 1
        }

        let total = order.count
        let p = RawArray<Int32>(capacity: total), ns = RawArray<UInt32>(capacity: total), nl = RawArray<UInt16>(capacity: total)
        let ks = RawArray<UInt32>(capacity: total), kl = RawArray<UInt16>(capacity: total)
        let sz = RawArray<Int64>(capacity: total), mt = RawArray<Int64>(capacity: total), fl = RawArray<UInt8>(capacity: total)
        let cs = RawArray<Int32>(capacity: total), cc = RawArray<Int32>(capacity: total)
        let nb = RawArray<UInt8>(capacity: max(nameBytes.count, 16))
        for (index, old) in order.enumerated() {
            let o = Int(old)
            p.append(o == 0 ? -1 : newId[Int(parent[o])])
            let start = UInt32(nb.count)
            ns.append(start); nl.append(nameLen[o])
            nb.append(contentsOf: UnsafeBufferPointer(start: nameBytes.pointer + Int(nameStart[o]), count: Int(nameLen[o])))
            kl.append(keyLen[o])
            if keyStart[o] == nameStart[o] {
                ks.append(start)
            } else {
                ks.append(UInt32(nb.count))
                nb.append(contentsOf: UnsafeBufferPointer(start: nameBytes.pointer + Int(keyStart[o]), count: Int(keyLen[o])))
            }
            sz.append(size[o]); mt.append(mtime[o]); fl.append(flags[o])
            cs.append(newChildStart[index]); cc.append(newChildCount[index])
        }

        // 이름 순서는 옮겨 적고, 정렬에 안 들어 있던 꼬리만 따로 정렬해 합친다.
        var remapped: [Int32] = []
        remapped.reserveCapacity(total)
        for old in nameOrder {
            let n = newId[Int(old)]
            if n > 0 { remapped.append(n) }
        }
        var tail: [Int32] = []
        if nameOrderCoverage < oldCount {
            for old in nameOrderCoverage..<oldCount {
                let n = newId[old]
                if n > 0 { tail.append(n) }
            }
        }

        parent = p; nameStart = ns; nameLen = nl; keyStart = ks; keyLen = kl
        size = sz; mtime = mt; flags = fl; childStart = cs; childCount = cc
        nameBytes = nb; extraChildren = [:]
        deletedCount = 0
        liveCountStorage = total - 1
        layoutEpoch &+= 1
        generation &+= 1

        let v = view()
        tail.sort { v.keyLess($0, $1) }
        nameOrder = Self.merge(remapped, tail, v)
        nameOrderCoverage = total
    }

    public func compact() {
        lock.write { compactLocked() }
    }

    static func merge(_ a: [Int32], _ b: [Int32], _ v: IndexView) -> [Int32] {
        if b.isEmpty { return a }
        if a.isEmpty { return b }
        var out: [Int32] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if v.keyLess(b[j], a[i]) { out.append(b[j]); j += 1 } else { out.append(a[i]); i += 1 }
        }
        if i < a.count { out.append(contentsOf: a[i...]) }
        if j < b.count { out.append(contentsOf: b[j...]) }
        return out
    }
}
