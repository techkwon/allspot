import CoreServices
import Foundation

public struct IndexConfiguration: Sendable, Equatable {
    public var roots: [String]
    public var excludedPaths: [String]
    /// 사정이 있어 이번에만 건너뛰는 폴더(예: 전체 디스크 접근 권한이 없어 열면 허용 창이 뜨는 폴더).
    /// 해시에 넣지 않으므로 이 목록이 바뀌어도 저장본을 버리지 않고, 새로 열린 폴더만 더 훑는다.
    public var skippedPaths: [String]

    public init(roots: [String] = ["/"], excludedPaths: [String] = IndexConfiguration.defaultExcludedPaths, skippedPaths: [String] = []) {
        // FSEvents는 심볼릭 링크를 푼 실제 경로(/tmp → /private/tmp)로 알려 주므로 뿌리도 실제 경로로 맞춘다.
        self.roots = roots.map { root in
            guard let resolved = realpath(root, nil) else { return root }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        self.excludedPaths = excludedPaths
        self.skippedPaths = skippedPaths
    }

    var allExcludedPaths: [String] { excludedPaths + skippedPaths }

    /// /System/Volumes는 /Users 등과 내용이 겹치고(firmlink), /Volumes는 외장·네트워크 디스크라 기본으로 뺀다.
    public static let defaultExcludedPaths = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores",
        "/private/var/vm", "/private/var/folders", "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100",
    ]

    /// 설정이 바뀌었는지 알아보는 고정 해시(FNV-1a). Swift의 Hasher는 실행마다 값이 달라 못 쓴다.
    public var stableHash: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (roots.joined(separator: "\n") + "\u{0}" + excludedPaths.joined(separator: "\n")).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

public enum IndexStatus: Equatable, Sendable {
    case starting
    case loadingCache
    case scanning(Int)
    case ready(Int)
}

/// 색인의 생애를 맡는다: 저장본 읽기 → (없으면) 전체 훑기 → FSEvents로 실시간 반영 → 주기적으로 저장.
public final class IndexController: @unchecked Sendable {
    public let index = FileIndex()
    public private(set) var configuration: IndexConfiguration
    public let cacheURL: URL?
    /// 읽기 전용: 저장본을 읽고 FSEvents로 따라잡기만 한다(저장·전체 훑기를 하지 않음). 앱 밖의 도구(CLI·MCP)가 쓴다.
    public let readOnly: Bool
    /// 읽기 전용인데 저장본이 없거나 맞지 않아 색인이 비었을 때 참
    public private(set) var cacheMissing = false

    /// 색인 내용이 바뀌었을 때(여러 번 불릴 수 있다).
    public var onChange: (@Sendable () -> Void)?
    public var onStatus: (@Sendable (IndexStatus) -> Void)?

    private let queue = DispatchQueue(label: "allspot.index", qos: .utility)
    private var stream: FSEventStreamRef?
    private var lastEventId: UInt64 = 0
    private var dirty = false
    private var saveTimer: DispatchSourceTimer?
    private var orderTimer: DispatchSourceTimer?
    private var scanCancelled = false
    private let caughtUpCondition = NSCondition()
    private var isCaughtUp = false
    private let loadedCondition = NSCondition()
    private var isLoaded = false

    public init(configuration: IndexConfiguration = IndexConfiguration(), cacheURL: URL? = IndexController.defaultCacheURL,
                readOnly: Bool = false) {
        self.configuration = configuration
        self.cacheURL = cacheURL
        self.readOnly = readOnly
    }

    /// 앱 설정(UserDefaults)에 맞춘 구성. 앱 밖의 도구가 앱이 저장한 색인을 그대로 읽을 때 쓴다.
    public static func appConfiguration() -> IndexConfiguration {
        let defaults = UserDefaults(suiteName: "com.techkwon.allspot")
        let excluded = defaults?.stringArray(forKey: "excludedPaths") ?? IndexConfiguration.defaultExcludedPaths
        return IndexConfiguration(roots: ["/"], excludedPaths: excluded)
    }

    /// 저장본을 읽은 뒤 저장 시점 이후의 변경(FSEvents 기록)을 다 받을 때까지 기다린다. 한 번 따라잡은 뒤에는 바로 돌아온다.
    @discardableResult
    public func waitUntilCaughtUp(timeout: TimeInterval) -> Bool {
        caughtUpCondition.lock()
        defer { caughtUpCondition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isCaughtUp {
            if !caughtUpCondition.wait(until: deadline) { return isCaughtUp }
        }
        return true
    }

    /// 저장본 불러오기(성공이든 없음이든)가 끝날 때까지 기다린다. 따라잡기를 건너뛰는 빠른 검색도 이것은 기다려야 한다.
    @discardableResult
    public func waitUntilLoaded(timeout: TimeInterval) -> Bool {
        loadedCondition.lock()
        defer { loadedCondition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isLoaded {
            if !loadedCondition.wait(until: deadline) { return isLoaded }
        }
        return true
    }

    private func signalLoaded() {
        loadedCondition.lock()
        isLoaded = true
        loadedCondition.broadcast()
        loadedCondition.unlock()
    }

    private func signalCaughtUp() {
        caughtUpCondition.lock()
        isCaughtUp = true
        caughtUpCondition.broadcast()
        caughtUpCondition.unlock()
    }

    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Allspot", isDirectory: true)
            .appendingPathComponent("index.v2.bin")
    }

    public func start() {
        queue.async { [self] in
            status(.loadingCache)
            let started = Date()
            if let cacheURL, let eventId = index.load(from: cacheURL, expectedConfigHash: configuration.stableHash) {
                if !readOnly { NSLog("Allspot: 저장본에서 \(index.liveCount)개 항목을 \(Int(Date().timeIntervalSince(started) * 1000))ms에 불러옴") }
                lastEventId = eventId
                status(.ready(index.liveCount))
                signalLoaded()
                onChange?()
                startWatching(since: eventId)
                if readOnly {
                    if eventId == 0 { signalCaughtUp() }
                    return
                }
                scanNewlyAllowedPaths()
                if index.loadedLegacyFormat {
                    // 예전 형식은 메모리로 다 읽어 들였으므로, 새 형식으로 바로 저장해 파일을 비춰 쓰게 한다.
                    dirty = true
                    save()
                }
            } else if readOnly {
                cacheMissing = true
                status(.ready(0))
                signalLoaded()
                signalCaughtUp()
                return
            } else {
                fullScanLocked()
            }
            startTimers()
        }
    }

    /// 설정을 바꾸고(또는 그대로) 처음부터 다시 훑는다.
    public func rebuild(configuration newConfiguration: IndexConfiguration? = nil) {
        scanCancelled = true
        queue.async { [self] in
            scanCancelled = false
            if let newConfiguration { configuration = newConfiguration }
            stopWatching()
            fullScanLocked()
        }
    }

    /// 지금까지의 색인을 저장한다. wait가 참이면 끝날 때까지 기다린다(앱 종료 때).
    public func save(wait: Bool = false) {
        let work = { [self] in
            guard dirty, !readOnly, let cacheURL else { return }
            do {
                try index.save(to: cacheURL, eventId: lastEventId, configHash: configuration.stableHash)
                try? configuration.skippedPaths.joined(separator: "\n").write(to: skippedListURL(cacheURL), atomically: true, encoding: .utf8)
                dirty = false
                // 압축하며 잠깐 두 배로 늘었던 메모리를 시스템에 돌려준다.
                malloc_zone_pressure_relief(nil, 0)
            } catch {
                NSLog("Allspot: 색인 저장 실패 \(error)")
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    // MARK: - 전체 훑기

    private func fullScanLocked() {
        let eventId = FSEventsGetCurrentEventId()
        index.reset()
        status(.scanning(0))
        let starts: [(Int32, String)] = index.lock.write {
            configuration.roots.map { root in (index.ensureDirectoryLocked(root), root) }
        }
        let scanner = makeScanner()
        scanner.onProgress = { [weak self] in
            guard let self else { return }
            self.status(.scanning(self.index.liveCount))
            self.onChange?()
        }
        let started = Date()
        scanner.scan(starts)
        guard !scanCancelled else { return }
        NSLog("Allspot: \(index.liveCount)개 항목을 \(String(format: "%.1f", Date().timeIntervalSince(started)))초에 읽음")
        index.rebuildNameOrder()
        lastEventId = eventId
        dirty = true
        status(.ready(index.liveCount))
        onChange?()
        // 훑는 동안 생긴 변경은 훑기 시작 시점의 번호부터 다시 받아 반영한다.
        startWatching(since: eventId)
        save()
    }

    private func makeScanner() -> Scanner {
        let scanner = Scanner(index: index, excluded: configuration.allExcludedPaths)
        scanner.isCancelled = { [weak self] in self?.scanCancelled ?? true }
        return scanner
    }

    private func skippedListURL(_ cacheURL: URL) -> URL {
        cacheURL.deletingPathExtension().appendingPathExtension("skipped.txt")
    }

    /// 저장할 때는 건너뛰었지만 지금은 열 수 있는 폴더(권한을 새로 받은 경우)만 더 훑는다.
    private func scanNewlyAllowedPaths() {
        guard let cacheURL, let saved = try? String(contentsOf: skippedListURL(cacheURL), encoding: .utf8) else { return }
        let previouslySkipped = saved.split(separator: "\n").map(String.init)
        let newlyAllowed = previouslySkipped.filter {
            !configuration.skippedPaths.contains($0) && !Scanner.isExcluded($0, configuration.excludedPaths)
        }
        guard !newlyAllowed.isEmpty else { return }
        let started = Date()
        for path in newlyAllowed { rescanSubtree(path) }
        NSLog("Allspot: 새로 열린 폴더 \(newlyAllowed.count)곳을 \(String(format: "%.1f", Date().timeIntervalSince(started)))초에 더 읽음")
        dirty = true
        status(.ready(index.liveCount))
        onChange?()
        save()
    }

    private func status(_ s: IndexStatus) {
        onStatus?(s)
    }

    private func startTimers() {
        let save = DispatchSource.makeTimerSource(queue: queue)
        save.schedule(deadline: .now() + 300, repeating: 300)
        save.setEventHandler { [weak self] in self?.save() }
        save.resume()
        saveTimer = save

        // 변경으로 늘어난 "정렬 안 된 꼬리"가 커지면 이름 순서를 다시 만든다.
        let order = DispatchSource.makeTimerSource(queue: queue)
        order.schedule(deadline: .now() + 30, repeating: 30)
        order.setEventHandler { [weak self] in
            guard let self else { return }
            if self.index.tombstoneRatio > 0.2 {
                self.index.compact()
                self.onChange?()
            } else if self.index.nameOrderLag > 20_000 {
                self.index.rebuildNameOrder()
            }
        }
        order.resume()
        orderTimer = order
    }

    // MARK: - FSEvents

    private func startWatching(since eventId: UInt64) {
        stopWatching()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let controller = Unmanaged<IndexController>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            var events: [(String, UInt32, UInt64)] = []
            events.reserveCapacity(count)
            for i in 0..<count { events.append((array[i], flags[i], ids[i])) }
            controller.handle(events)
        }
        let createFlags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, configuration.roots as CFArray,
                                               eventId == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : eventId,
                                               readOnly ? 0.05 : 1.0, createFlags) else {
            NSLog("Allspot: FSEvents 감시를 시작하지 못함")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// FSEvents 묶음을 처리한다(색인 큐에서 불린다).
    func handle(_ events: [(String, UInt32, UInt64)]) {
        let mustScan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        var shallow = Set<String>()
        var deep = Set<String>()
        var historyDone = false
        // 기록을 다 받았으면 이 묶음까지 반영한 뒤 기다리는 쪽(waitUntilCaughtUp)을 깨운다.
        defer { if historyDone { signalCaughtUp() } }
        for (rawPath, flags, id) in events {
            if Self.debug { NSLog("Allspot 이벤트: \(rawPath) flags=\(String(flags, radix: 16)) id=\(id)") }
            if id > lastEventId { lastEventId = id }
            if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { historyDone = true; continue }
            if flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { continue }
            let path = Self.normalize(rawPath)
            if Scanner.isExcluded(path, configuration.allExcludedPaths) { continue }
            if flags & mustScan != 0 || flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                deep.insert(path)
            } else {
                shallow.insert(path)
            }
        }
        guard !shallow.isEmpty || !deep.isEmpty else { return }
        let before = index.lock.read { index.generation }
        for path in deep { rescanSubtree(path) }
        for path in shallow where !deep.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
            rescanDirectory(path, depth: 0)
        }
        if index.lock.read({ index.generation }) != before {
            dirty = true
            status(.ready(index.liveCount))
            onChange?()
        }
    }

    static let debug = ProcessInfo.processInfo.environment["ALLSPOT_DEBUG"] != nil

    /// FSEvents가 데이터 볼륨의 실제 경로(/System/Volumes/Data/...)로 알려 줄 때를 대비해 보통 경로로 바꾼다.
    static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/System/Volumes/Data/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    private func isInsideRoots(_ path: String) -> Bool {
        configuration.roots.contains { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }
    }

    private func rescanDirectory(_ path: String, depth: Int) {
        guard depth < 64, isInsideRoots(path) else { return }
        let parentPath = (path as NSString).deletingLastPathComponent
        guard let id = index.lookup(path), index.lock.read({ index.flags[Int(id)] & EntryFlag.directory != 0 }) else {
            // 아직 색인에 없는 폴더면 부모를 다시 읽어 새 폴더를 들인다.
            if parentPath != path { rescanDirectory(parentPath, depth: depth + 1) }
            return
        }
        var batch = EntryBatch()
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        let error = Scanner.list(path, into: &batch, buffer: buffer, bufferSize: bufferSize)
        if Self.debug { NSLog("Allspot 다시 읽기: \(path) id=\(id) 오류=\(error) 항목=\(batch.count)") }
        if error == ENOENT || error == ENOTDIR {
            if parentPath != path { rescanDirectory(parentPath, depth: depth + 1) }
            return
        }
        guard error == 0 else { return }
        let newDirectories = index.applyListing(batch, to: id, dirPath: path)
            .filter { !Scanner.isExcluded($0.1, configuration.allExcludedPaths) }
        if !newDirectories.isEmpty {
            makeScanner().scan(newDirectories)
        }
    }

    private func rescanSubtree(_ path: String) {
        guard let id = index.lookup(path) else {
            rescanDirectory(path, depth: 0)
            return
        }
        index.lock.write { index.tombstoneLocked(id, includingSelf: false) }
        makeScanner().scan([(id, path)])
    }
}
