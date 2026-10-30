import Darwin
import Foundation

extension TextKey {
    /// 본문 비교용 키: 공백 덩어리를 빈칸 하나로 줄이고 NFC·소문자로 맞춘다.
    static func contentKey(_ text: String) -> [UInt8] {
        key(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
    }
}

/// 문서(hwp·hwpx·pdf·docx·pptx·xlsx·txt·md)의 본문을 미리 읽어 둔 자체 내용 색인.
/// Spotlight은 한글 문서 내용을 읽지 못하고 느리므로 이 색인이 먼저 답한다.
///
/// 본문은 저장본 파일을 그대로 비춰(mmap) 쓰고, 불러온 뒤 새로 읽은 문서만 메모리(extra)에 덧붙인다.
/// 저장하면 다시 한 파일로 모아 비춰 쓰므로 본문이 수백 MB여도 앱 몫 메모리는 거의 늘지 않는다.
public final class ContentIndex: @unchecked Sendable {
    struct Document {
        var size: Int64
        var mtime: Int64
        /// 본문 위치(비춘 구간 길이보다 작으면 비춘 곳, 아니면 extra 안)
        var textStart: Int
        var textLength: Int
        var author: [UInt8]
    }

    let lock = RWLock()
    private var paths: [String] = []
    private var documents: [Document] = []
    private var slots: [String: Int] = [:]
    /// 저장본에서 비춘 본문
    private var mapped: UnsafeMutableRawPointer?
    private var mappedLength = 0
    /// 불러온 뒤 새로 읽은 본문
    private var extra = RawArray<UInt8>(capacity: 0)
    /// 지워지거나 바뀐 문서가 남긴 본문 바이트 수(저장할 때 걷어 낸다)
    private var garbage = 0
    /// 바뀔 때마다 늘어난다(저장 중에 바뀌었는지 알아보려고)
    private var generation: UInt64 = 0
    private(set) var dirty = false

    public init() {}

    deinit { unmap() }

    public var count: Int { lock.read { slots.count } }
    /// 본문 전체 크기(바이트, 걷어 낼 몫 포함)
    public var textBytes: Int { lock.read { mappedLength + extra.count } }
    /// 아직 파일로 저장하지 않아 메모리에 있는 본문 크기
    var unsavedBytes: Int { lock.read { extra.count } }

    public func contains(_ path: String) -> Bool { lock.read { slots[path] != nil } }

    func isCurrent(_ path: String, size: Int64, mtime: Int64) -> Bool {
        lock.read {
            guard let slot = slots[path] else { return false }
            return documents[slot].size == size && documents[slot].mtime == mtime
        }
    }

    var allPaths: [String] { lock.read { Array(slots.keys) } }

    public func set(_ path: String, size: Int64, mtime: Int64, text body: [UInt8], author: [UInt8]) {
        lock.write {
            let document = Document(size: size, mtime: mtime, textStart: mappedLength + extra.count, textLength: body.count, author: author)
            extra.append(contentsOf: body)
            if let slot = slots[path] {
                garbage += documents[slot].textLength
                documents[slot] = document
            } else {
                slots[path] = documents.count
                paths.append(path)
                documents.append(document)
            }
            generation &+= 1
            dirty = true
        }
    }

    func remove(_ path: String) {
        lock.write {
            guard let slot = slots.removeValue(forKey: path) else { return }
            garbage += documents[slot].textLength
            documents[slot].textLength = 0
            documents[slot].author = []
            paths[slot] = ""
            generation &+= 1
            dirty = true
        }
    }

    /// 본문(또는 작성자)에 key가 든 문서의 경로. 모든 코어로 나눠 훑는다.
    public func search(_ key: [UInt8], inAuthor: Bool = false, cancel: CancelToken? = nil) -> [String] {
        guard !key.isEmpty else { return [] }
        return lock.read {
            let count = documents.count
            guard count > 0 else { return [] }
            let chunkSize = 64
            let chunks = (count + chunkSize - 1) / chunkSize
            var found = [[Int]](repeating: [], count: chunks)
            let base = mapped.map { UnsafeRawPointer($0) }
            let baseLength = mappedLength
            do {
                let added = UnsafeBufferPointer(start: extra.pointer, count: extra.count)
                key.withUnsafeBufferPointer { needle in
                    documents.withUnsafeBufferPointer { docs in
                        found.withUnsafeMutableBufferPointer { results in
                            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                                if cancel?.isCancelled == true { return }
                                var local: [Int] = []
                                for slot in (chunk * chunkSize)..<min(count, (chunk + 1) * chunkSize) {
                                    let d = docs[slot]
                                    let hit: Bool
                                    if inAuthor {
                                        hit = d.author.withUnsafeBufferPointer {
                                            memmem($0.baseAddress, $0.count, needle.baseAddress, needle.count) != nil
                                        }
                                    } else if d.textLength < needle.count {
                                        hit = false
                                    } else {
                                        let start = d.textStart < baseLength
                                            ? base! + d.textStart
                                            : UnsafeRawPointer(added.baseAddress! + (d.textStart - baseLength))
                                        hit = memmem(start, d.textLength, needle.baseAddress, needle.count) != nil
                                    }
                                    if hit { local.append(slot) }
                                }
                                results[chunk] = local
                            }
                        }
                    }
                }
            }
            return found.flatMap { $0 }.map { paths[$0] }.filter { !$0.isEmpty }
        }
    }

    // MARK: - 저장

    private static let magic: UInt32 = 0x4943_5341 // "ASCI"
    /// 형식 2: 머리말 · 문서 목록 · (16KB 경계) 본문. 형식 1(본문이 문서 사이사이에 낀 예전 형식)도 읽는다.
    private static let formatVersion: UInt32 = 2
    private static let legacyFormatVersion: UInt32 = 1
    private static let headerBytes = 40

    /// 남은 문서만 모아 한 파일로 쓰고(임시 파일에 쓰고 이름을 바꿈), 그동안 바뀐 것이 없으면 새 파일을 비춰 쓴다.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        let (saved, layout): (UInt64, [(slot: Int, start: Int)]) = try lock.read {
            var meta = Data()
            func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { meta.append(contentsOf: $0) } }
            func putBytes(_ bytes: [UInt8]) { put(UInt32(bytes.count)); meta.append(contentsOf: bytes) }
            var layout: [(slot: Int, start: Int)] = []
            layout.reserveCapacity(slots.count)
            var textBytes = 0
            for (path, slot) in slots {
                let d = documents[slot]
                putBytes(Array(path.utf8))
                put(d.size)
                put(d.mtime)
                putBytes(d.author)
                put(UInt64(textBytes))
                put(UInt64(d.textLength))
                layout.append((slot, textBytes))
                textBytes += d.textLength
            }
            let textOffset = RawArray<UInt8>.aligned(Self.headerBytes + meta.count)
            var header = Data()
            for value: UInt32 in [Self.magic, Self.formatVersion, UInt32(slots.count), 0] {
                withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
            }
            for value in [UInt64(meta.count), UInt64(textOffset), UInt64(textBytes)] {
                withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
            }
            guard let file = fopen(temporary.path, "wb") else { throw CocoaError(.fileWriteUnknown) }
            var ok = true
            func write(_ pointer: UnsafeRawPointer?, _ bytes: Int) {
                if bytes > 0, let pointer, fwrite(pointer, 1, bytes, file) != bytes { ok = false }
            }
            header.withUnsafeBytes { write($0.baseAddress, $0.count) }
            meta.withUnsafeBytes { write($0.baseAddress, $0.count) }
            let padding = [UInt8](repeating: 0, count: textOffset - Self.headerBytes - meta.count)
            padding.withUnsafeBytes { write($0.baseAddress, $0.count) }
            do {
                let added = UnsafeRawBufferPointer(start: extra.pointer, count: extra.count)
                for (slot, _) in layout {
                    let d = documents[slot]
                    if d.textStart < mappedLength {
                        write(mapped! + d.textStart, d.textLength)
                    } else {
                        write(added.baseAddress! + (d.textStart - mappedLength), d.textLength)
                    }
                }
            }
            if fclose(file) != 0 { ok = false }
            guard ok else {
                unlink(temporary.path)
                throw CocoaError(.fileWriteUnknown)
            }
            return (generation, layout)
        }
        Self.keepBackupIfShrinking(url, newCount: layout.count)
        if rename(temporary.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
        // 쓰는 동안 바뀐 것이 없으면 메모리의 본문을 버리고 방금 쓴 파일을 비춰 쓴다.
        lock.write {
            guard generation == saved, let region = Self.mapText(url) else { return }
            var newPaths: [String] = []
            var newDocuments: [Document] = []
            var newSlots: [String: Int] = [:]
            newPaths.reserveCapacity(layout.count)
            newDocuments.reserveCapacity(layout.count)
            for (slot, start) in layout {
                var d = documents[slot]
                d.textStart = start
                newSlots[paths[slot]] = newDocuments.count
                newPaths.append(paths[slot])
                newDocuments.append(d)
            }
            unmap()
            mapped = region.pointer
            mappedLength = region.length
            extra = RawArray<UInt8>(capacity: 0)
            paths = newPaths
            documents = newDocuments
            slots = newSlots
            garbage = 0
            dirty = false
        }
    }

    private func unmap() {
        if let mapped { munmap(mapped, mappedLength) }
        mapped = nil
        mappedLength = 0
    }

    /// 저장본의 본문 구간만 읽기 전용으로 비춘다.
    private static func mapText(_ url: URL) -> (pointer: UnsafeMutableRawPointer?, length: Int)? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let header = readHeader(fd), header.version == formatVersion else { return nil }
        return map(fd, header)
    }

    private struct Header {
        var version: UInt32
        var count: Int
        var metaBytes: Int
        var textOffset: Int
        var textBytes: Int
    }

    private static func readHeader(_ fd: Int32) -> Header? {
        var raw = [UInt8](repeating: 0, count: headerBytes)
        guard raw.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, headerBytes, 0) }) >= 12 else { return nil }
        func u32(_ i: Int) -> UInt32 { raw.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self)) } }
        func u64(_ i: Int) -> Int { raw.withUnsafeBytes { Int(truncatingIfNeeded: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt64.self))) } }
        guard u32(0) == magic else { return nil }
        return Header(version: u32(4), count: Int(u32(8)), metaBytes: u64(16), textOffset: u64(24), textBytes: u64(32))
    }

    private static func map(_ fd: Int32, _ header: Header) -> (pointer: UnsafeMutableRawPointer?, length: Int)? {
        var st = stat()
        // 파일이 잘렸으면 비춘 곳을 읽다가 앱이 죽으므로 길이를 먼저 확인한다.
        guard fstat(fd, &st) == 0, header.textOffset >= 0, header.textBytes >= 0, Int(st.st_size) >= header.textOffset,
              header.textBytes <= Int(st.st_size) - header.textOffset else { return nil }
        guard header.textBytes > 0 else { return (nil, 0) }
        let pointer = mmap(nil, header.textBytes, PROT_READ, MAP_PRIVATE, fd, off_t(header.textOffset))
        guard let pointer, pointer != MAP_FAILED else { return nil }
        return (pointer, header.textBytes)
    }

    /// 저장본이 절반 아래로 줄어들 때는(클라우드 드라이브가 끊겼거나 예상 못 한 사고) 덮어쓰기 전 것을 .bak으로 남긴다.
    /// 다시 읽으면 되는 자료지만, 문서가 많으면 처음부터 읽는 데 몇 분이 걸리므로 되돌릴 길을 둔다.
    private static func keepBackupIfShrinking(_ url: URL, newCount: Int) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        let old = readHeader(fd)
        close(fd)
        guard let old, old.count >= 1_000, newCount < old.count / 2 else { return }
        let backup = url.appendingPathExtension("bak")
        _ = rename(url.path, backup.path)
        NSLog("Allspot: 내용 색인이 \(old.count)개에서 \(newCount)개로 줄어 이전 저장본을 \(backup.lastPathComponent)로 남김")
    }

    public func load(from url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard let header = Self.readHeader(fd) else { return false }
        if header.version == Self.legacyFormatVersion { return loadLegacy(url) }
        guard header.version == Self.formatVersion, header.metaBytes >= 0, header.metaBytes < 1 << 30,
              header.textOffset >= Self.headerBytes + header.metaBytes else { return false }
        var meta = [UInt8](repeating: 0, count: header.metaBytes)
        guard meta.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, header.metaBytes, off_t(Self.headerBytes)) }) == header.metaBytes
        else { return false }
        var reader = ByteReader(bytes: meta)
        var newPaths: [String] = []
        var newDocuments: [Document] = []
        var newSlots: [String: Int] = [:]
        for _ in 0..<header.count {
            guard let path = reader.chunk(), let size = reader.get(Int64.self), let mtime = reader.get(Int64.self),
                  let author = reader.chunk(), let start = reader.get(UInt64.self), let length = reader.get(UInt64.self),
                  start <= UInt64(header.textBytes), length <= UInt64(header.textBytes) - start else { return false }
            let name = String(decoding: path, as: UTF8.self)
            newSlots[name] = newDocuments.count
            newPaths.append(name)
            newDocuments.append(Document(size: size, mtime: mtime, textStart: Int(start), textLength: Int(length), author: Array(author)))
        }
        guard let region = Self.map(fd, header) else { return false }
        lock.write {
            unmap()
            mapped = region.pointer
            mappedLength = region.length
            extra = RawArray<UInt8>(capacity: 0)
            paths = newPaths
            documents = newDocuments
            slots = newSlots
            garbage = 0
            generation &+= 1
            dirty = false
        }
        return true
    }

    /// 형식 1은 메모리로 읽어 들이고, 다음 저장 때 형식 2로 바꾼다.
    private func loadLegacy(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        var reader = ByteReader(bytes: [UInt8](data))
        guard reader.get(UInt32.self) == Self.magic, reader.get(UInt32.self) == Self.legacyFormatVersion,
              let count = reader.get(UInt32.self) else { return false }
        var newText: [UInt8] = []
        var newPaths: [String] = []
        var newDocuments: [Document] = []
        var newSlots: [String: Int] = [:]
        for _ in 0..<count {
            guard let path = reader.chunk(), let size = reader.get(Int64.self), let mtime = reader.get(Int64.self),
                  let author = reader.chunk(), let body = reader.chunk() else { return false }
            let name = String(decoding: path, as: UTF8.self)
            newSlots[name] = newDocuments.count
            newPaths.append(name)
            newDocuments.append(Document(size: size, mtime: mtime, textStart: newText.count, textLength: body.count, author: Array(author)))
            newText.append(contentsOf: body)
        }
        lock.write {
            unmap()
            extra = RawArray<UInt8>(capacity: newText.count)
            extra.append(contentsOf: newText)
            paths = newPaths
            documents = newDocuments
            slots = newSlots
            garbage = 0
            generation &+= 1
            dirty = true
        }
        return true
    }
}

/// 작은 이진 읽기 도우미(리틀 엔디언)
private struct ByteReader {
    let bytes: [UInt8]
    var p = 0

    mutating func get<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard p + MemoryLayout<T>.size <= bytes.count else { return nil }
        defer { p += MemoryLayout<T>.size }
        return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: T.self)) }
    }

    mutating func chunk() -> ArraySlice<UInt8>? {
        guard let n = get(UInt32.self), p + Int(n) <= bytes.count else { return nil }
        defer { p += Int(n) }
        return bytes[p..<(p + Int(n))]
    }
}

public struct ContentIndexStatus: Sendable, Equatable {
    /// 내용을 읽어 둔 문서 수
    public var indexed = 0
    /// 색인 대상(로컬에 있는) 문서 수
    public var total = 0
    /// 아직 읽을 차례를 기다리는 문서 수
    public var pending = 0
    /// 클라우드에만 있어 건너뛴 문서 수
    public var cloudSkipped = 0
    public var isRunning = false

    public init() {}
}

/// 파일 이름 색인에서 문서를 찾아 바뀐 것만 뒤에서 읽어 내용 색인을 최신으로 유지한다.
public final class ContentIndexer: @unchecked Sendable {
    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Allspot/content.v1.bin")
    }

    public let content = ContentIndex()
    private let fileIndex: FileIndex
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "allspot.content", qos: .utility)
    private let stateLock = NSLock()
    private var includeCloud = false
    private var enabled = true
    private var started = false
    private var running = false
    private var rerunRequested = false
    private var scheduled = false
    private var lastSaved = Date()
    private var status = ContentIndexStatus()
    private let saveLock = NSLock()

    /// 문서를 읽을 도우미 프로세스(앱 묶음의 Helpers/allspot). 없으면 이 프로세스에서 직접 읽는다.
    public var workerURL: URL?

    public var onStatus: (@Sendable (ContentIndexStatus) -> Void)?

    public init(fileIndex: FileIndex, cacheURL: URL = ContentIndexer.defaultCacheURL) {
        self.fileIndex = fileIndex
        self.cacheURL = cacheURL
    }

    /// 클라우드에만 있는 파일도 읽을지(읽으면 내려받는다)
    public func configure(enabled: Bool, includeCloud: Bool) {
        stateLock.lock()
        let changed = enabled != self.enabled || includeCloud != self.includeCloud
        self.enabled = enabled
        self.includeCloud = includeCloud
        let wasStarted = started
        stateLock.unlock()
        if changed && wasStarted { scheduleReconcile(after: 0) }
    }

    /// 파일 이름 색인이 준비된 뒤 한 번 부른다. 저장본을 읽고 바뀐 문서를 따라잡는다.
    public func start() {
        stateLock.lock()
        guard !started else { stateLock.unlock(); return }
        started = true
        stateLock.unlock()
        queue.async { [self] in
            let t = Date()
            if content.load(from: cacheURL) {
                NSLog("Allspot: 내용 색인 저장본에서 \(content.count)개 문서를 \(Int(Date().timeIntervalSince(t) * 1000))ms에 불러옴")
            }
            reconcile()
        }
    }

    /// 파일 이름 색인이 바뀌면 부른다. 잦은 변경은 묶어서 한 번만 따라잡는다.
    public func scheduleReconcile(after delay: TimeInterval = 15) {
        stateLock.lock()
        guard started, !scheduled else { stateLock.unlock(); return }
        if running {
            // 지금 도는 일이 끝나면 한 번 더 한다.
            rerunRequested = true
            stateLock.unlock()
            return
        }
        scheduled = true
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            stateLock.lock()
            scheduled = false
            stateLock.unlock()
            reconcile()
        }
    }

    /// 지금 맡은 일(불러오기·따라잡기)이 끝날 때까지 기다린다. 확인용 도구에서 쓴다.
    public func waitUntilIdle() {
        queue.sync {}
    }

    public func save() {
        queue.async { [self] in saveIfNeeded(force: true) }
    }

    /// 앱을 끝낼 때: 지금까지 읽은 것을 바로 저장한다.
    public func saveNow() {
        saveLock.lock()
        defer { saveLock.unlock() }
        guard content.dirty else { return }
        try? content.save(to: cacheURL)
    }

    /// 저장하면 새로 읽은 본문(메모리)을 파일 비추기로 바꾸므로, 오래되었거나 많이 쌓였으면 저장한다.
    private func saveIfNeeded(force: Bool) {
        // 여러 읽기 줄이 함께 부르므로, 누가 저장 중이면 이번에는 건너뛴다(마지막에 꼭 한 번 저장한다).
        if force { saveLock.lock() } else if !saveLock.try() { return }
        defer { saveLock.unlock() }
        guard content.dirty, force || Date().timeIntervalSince(lastSaved) > 60 || content.unsavedBytes > 24 << 20 else { return }
        do {
            try content.save(to: cacheURL)
            lastSaved = Date()
            // 다 읽고 버린 문서 버퍼·본문이 남긴 빈 메모리를 시스템에 돌려준다.
            malloc_zone_pressure_relief(nil, 0)
        } catch {
            NSLog("Allspot: 내용 색인을 저장하지 못함 \(error)")
        }
    }

    private func publish(_ change: (inout ContentIndexStatus) -> Void) {
        stateLock.lock()
        change(&status)
        let snapshot = status
        stateLock.unlock()
        onStatus?(snapshot)
    }

    private func reconcile() {
        stateLock.lock()
        rerunRequested = false
        running = true
        let enabled = enabled, includeCloud = includeCloud
        stateLock.unlock()
        defer {
            stateLock.lock()
            running = false
            let again = rerunRequested
            rerunRequested = false
            stateLock.unlock()
            publish { $0.isRunning = false; $0.pending = 0 }
            if again { scheduleReconcile() }
        }
        guard enabled else { return }

        // 1) 파일 이름 색인에서 지금 있는 문서를 모은다.
        let extensions = DocumentText.indexedExtensions.sorted().joined(separator: ";")
        guard let query = try? CompiledQuery.compile("ext:\(extensions) file:") else { return }
        let outcome = fileIndex.search(query)
        var candidates: [(path: String, size: Int64, mtime: Int64)] = []
        candidates.reserveCapacity(outcome.ids.count)
        for id in outcome.ids {
            guard let info = fileIndex.info(id, epoch: outcome.epoch) else { continue }
            let path = info.fullPath
            guard Self.isCandidate(path, size: info.size) else { continue }
            candidates.append((path, info.size, Int64(info.modified.timeIntervalSince1970)))
        }
        let present = Set(candidates.map(\.path))
        removeMissing(present)

        // 2) 새로 생기거나 바뀐 것만 읽는다. 클라우드에만 있는 파일은 (설정이 꺼져 있으면) 건너뛴다.
        var todo: [(path: String, size: Int64, mtime: Int64)] = []
        var cloudSkipped = 0
        for c in candidates where !content.isCurrent(c.path, size: c.size, mtime: c.mtime) {
            var st = stat()
            guard lstat(c.path, &st) == 0 else { continue }
            if st.st_flags & UInt32(SF_DATALESS) != 0 && !includeCloud {
                cloudSkipped += 1
                continue
            }
            todo.append(c)
        }
        let total = candidates.count - cloudSkipped
        publish {
            $0.total = total
            $0.cloudSkipped = cloudSkipped
            $0.pending = todo.count
            $0.indexed = total - todo.count
            $0.isRunning = !todo.isEmpty
        }
        guard !todo.isEmpty else { return }
        NSLog("Allspot: 문서 \(todo.count)개의 내용을 읽음 (클라우드 전용 \(cloudSkipped)개 건너뜀)")

        let started = Date()
        if let workerURL {
            readWithWorkers(workerURL, todo, total: total, includeCloud: includeCloud)
        } else {
            readInProcess(todo, total: total, includeCloud: includeCloud)
        }
        saveIfNeeded(force: true)
        NSLog("Allspot: 내용 색인 \(todo.count)개를 \(String(format: "%.1f", Date().timeIntervalSince(started)))초에 읽음")
    }

    /// 클라우드 드라이브가 잠깐 끊기면 그 아래 문서가 이름 색인에서 통째로 빠졌다 돌아온다.
    /// 그때마다 지우고 다시 읽지 않도록, 폴더째 안 보이는 문서는 이 기간 동안 남겨 둔다.
    static let missingGrace: TimeInterval = 3 * 24 * 3600
    private var missingSince: [String: Date] = [:]

    /// 이름 색인에 없는 문서를 정리한다. 정말 지워진 것(폴더는 있는데 파일만 없음)과 규칙 밖으로 나간 것만 바로 뺀다.
    private func removeMissing(_ present: Set<String>) {
        let now = Date()
        for path in missingSince.keys where present.contains(path) { missingSince[path] = nil }
        for path in content.allPaths where !present.contains(path) {
            var st = stat()
            if lstat(path, &st) == 0 {
                // 파일은 있는데 이름 색인이 아직 모르면 둔다.
                if !Self.isCandidate(path, size: Int64(st.st_size)) { content.remove(path) }
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            let since = missingSince[path] ?? now
            if lstat(parent, &st) == 0 || now.timeIntervalSince(since) > Self.missingGrace {
                content.remove(path)
                missingSince[path] = nil
            } else {
                missingSince[path] = since
            }
        }
    }

    private var isEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return enabled
    }

    /// 도우미 프로세스 몇 개가 16개씩 나눠 읽는다. 도우미가 어떤 문서에서 죽거나 멈추면 그 문서만 빈 본문으로 넣고 나머지를 잇는다.
    private func readWithWorkers(_ worker: URL, _ todo: [(path: String, size: Int64, mtime: Int64)], total: Int, includeCloud: Bool) {
        let chunkSize = 16
        let lanes = 4
        let lock = NSLock()
        var next = 0
        var done = 0
        DispatchQueue.concurrentPerform(iterations: lanes) { _ in
            while isEnabled {
                lock.lock()
                let start = next
                next += chunkSize
                lock.unlock()
                guard start < todo.count else { return }
                var chunk = Array(todo[start..<min(todo.count, start + chunkSize)])
                while !chunk.isEmpty {
                    let received = ContentWorker.run(worker: worker, paths: chunk.map(\.path), includeCloud: includeCloud) { i, keys in
                        let c = chunk[i]
                        content.set(c.path, size: c.size, mtime: c.mtime, text: keys?.body ?? [], author: keys?.author ?? [])
                    }
                    guard received < chunk.count else { break }
                    let bad = chunk[received]
                    NSLog("Allspot: 읽다가 도우미가 멈춘 문서는 건너뜀 \(bad.path)")
                    content.set(bad.path, size: bad.size, mtime: bad.mtime, text: [], author: [])
                    chunk.removeFirst(received + 1)
                }
                lock.lock()
                done += min(chunkSize, todo.count - start)
                let remaining = todo.count - done
                lock.unlock()
                publish { $0.pending = remaining; $0.indexed = total - remaining }
                saveIfNeeded(force: false)
            }
        }
    }

    private func readInProcess(_ todo: [(path: String, size: Int64, mtime: Int64)], total: Int, includeCloud: Bool) {
        let batch = 4
        var done = 0
        while done < todo.count && isEnabled {
            let slice = todo[done..<min(todo.count, done + batch)]
            DispatchQueue.concurrentPerform(iterations: slice.count) { k in
                let c = slice[slice.startIndex + k]
                index(c.path, size: c.size, mtime: c.mtime, includeCloud: includeCloud)
            }
            done += slice.count
            let remaining = todo.count - done
            publish { $0.pending = remaining; $0.indexed = total - remaining }
            saveIfNeeded(force: false)
        }
    }

    /// 문서 하나의 본문 키와 작성자 키(도우미 프로세스와 앱이 함께 쓴다).
    public static func extractKeys(path: String) -> (body: [UInt8], author: [UInt8])? {
        guard let extracted = DocumentText.extract(path: path, plainTextLimit: plainTextLimit) else { return nil }
        return (TextKey.contentKey(extracted.text), extracted.author.map { TextKey.contentKey($0) } ?? [])
    }

    /// 문서 하나를 읽어 내용 색인에 넣는다. 읽지 못한 문서도 빈 본문으로 넣어 다시 시도하지 않게 한다(바뀌면 다시 읽음).
    private func index(_ path: String, size: Int64, mtime: Int64, includeCloud: Bool) {
        // 클라우드 전용 파일을 실수로 내려받지 않게 이 스레드에서는 자리표시 파일 읽기를 막는다.
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           includeCloud ? IOPOL_MATERIALIZE_DATALESS_FILES_ON : IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let keys = Self.extractKeys(path: path)
        content.set(path, size: size, mtime: mtime, text: keys?.body ?? [], author: keys?.author ?? [])
    }

    /// 글자 파일(txt·md)은 이 크기까지만 넣는다(로그·데이터 덤프는 뺀다).
    static let plainTextLimit = 1 << 20
    static let sizeLimit: Int64 = 300 << 20

    /// 개발 도구·앱이 만든 파일이 섞인 폴더 이름(글자 파일은 이 안의 것을 넣지 않는다)
    static let developerFolders: Set<String> = [
        "node_modules", "build", "dist", "target", "vendor", "Pods", "DerivedData", "site-packages",
        "venv", "__pycache__", "bower_components", "out", "coverage",
    ]

    /// 내용 색인에 넣을 파일인지. 시스템·앱 내부 파일과 개발 폴더의 글자 파일을 뺀다.
    public static func isCandidate(_ path: String, size: Int64) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard DocumentText.indexedExtensions.contains(ext), size > 0, size < sizeLimit else { return false }
        let plain = DocumentText.plainExtensions.contains(ext)
        if plain && size > Int64(plainTextLimit) { return false }
        guard path.hasPrefix("/Users/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        // /Users/<이름>/Library 아래는 클라우드 드라이브(와 카카오톡 같은 앱이 받은 문서)만 넣는다.
        if parts.count > 3 && parts[2] == "Library" {
            switch parts[3] {
            case "Mobile Documents", "CloudStorage": break
            case "Containers" where !plain: break
            default: return false
            }
        }
        for part in parts.dropLast() {
            if part.hasPrefix(".") { return false }
            if part.hasSuffix(".app") || part.hasSuffix(".framework") || part.hasSuffix(".bundle") { return false }
            if plain && developerFolders.contains(String(part)) { return false }
        }
        // 글자 파일은 개발 폴더(~/Developer, 저장소 안) 것을 넣지 않는다.
        if plain && parts.count > 2 && parts[2] == "Developer" { return false }
        return true
    }
}
