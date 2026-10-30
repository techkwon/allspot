import AllspotCore
import AppKit
import Combine
import Foundation

/// 결과 내 검색으로 고정해 둔 앞 단계 검색어
struct Refinement: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let fuzzy: Bool
    /// 고정할 때의 결과 수
    let count: Int
}

/// 즐겨찾기한 검색: 결과 내 검색 단계까지 그대로 다시 연다.
struct Bookmark: Codable, Hashable, Identifiable {
    /// 앞 단계부터 마지막 검색어까지
    var stages: [String]
    var fuzzy: Bool
    var id: [String] { stages }
    var title: String { stages.joined(separator: " › ") + (fuzzy ? "  (유사)" : "") }
}

@MainActor
final class SearchModel: ObservableObject {
    static let excludedPathsKey = "excludedPaths"
    static let fuzzyModeKey = "fuzzySearch"
    static let indexContentsKey = "indexDocumentContents"
    static let includeCloudKey = "includeCloudDocuments"
    static let recentQueriesKey = "recentQueries"
    static let bookmarksKey = "bookmarks"

    let controller: IndexController
    /// 문서 내용 색인(hwp·hwpx·pdf·docx·pptx·xlsx·txt·md)
    let contentIndexer: ContentIndexer
    /// content:·tag:·author:·taken:·spotlight: 조건의 답을 구해 온다
    let externalSearcher: ExternalSearcher

    @Published var query = "" {
        didSet { if query != oldValue { runSearch() } }
    }
    /// 켜면 검색어 전체를 유사 검색(오타·건너뛰기·초성 허용)으로 찾는다.
    @Published var fuzzyMode = UserDefaults.standard.bool(forKey: SearchModel.fuzzyModeKey) {
        didSet {
            guard fuzzyMode != oldValue else { return }
            UserDefaults.standard.set(fuzzyMode, forKey: Self.fuzzyModeKey)
            runSearch()
        }
    }
    /// 문서 내용을 뒤에서 읽어 둘지
    @Published var indexDocumentContents = UserDefaults.standard.object(forKey: SearchModel.indexContentsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(indexDocumentContents, forKey: Self.indexContentsKey)
            configureContentIndexer()
        }
    }
    /// 클라우드에만 있는 문서도 내려받아 읽을지
    @Published var includeCloudDocuments = UserDefaults.standard.bool(forKey: SearchModel.includeCloudKey) {
        didSet {
            UserDefaults.standard.set(includeCloudDocuments, forKey: Self.includeCloudKey)
            configureContentIndexer()
        }
    }
    @Published private(set) var contentStatus = ContentIndexStatus()
    /// Spotlight·내용 색인에서 답을 구해 오는 중
    @Published private(set) var isSearchingOutside = false
    /// 결과 내 검색: 앞 단계 검색어들. 지금 검색어와 함께 모두 맞아야 한다.
    @Published private(set) var refinements: [Refinement] = []
    /// 최근 검색어(새 것이 앞). 결과가 있는 검색어를 잠시 그대로 두면 남긴다.
    @Published private(set) var recentQueries = UserDefaults.standard.stringArray(forKey: SearchModel.recentQueriesKey) ?? []
    private var recordRecent: DispatchWorkItem?
    /// 즐겨찾기한 검색(추가한 순서)
    @Published private(set) var bookmarks: [Bookmark] = {
        guard let data = UserDefaults.standard.data(forKey: SearchModel.bookmarksKey) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }()
    @Published private(set) var resultCount = 0
    @Published private(set) var resultsVersion = 0
    @Published private(set) var indexStatus: IndexStatus = .starting
    @Published private(set) var searchMillis: Double = 0
    @Published private(set) var queryError: String?
    @Published private(set) var hasFullDiskAccess = true
    @Published var excludedDraft = ""
    /// 설정 창에서 고치는 중인 "AI 도구에서 숨길 폴더" 목록
    @Published var aiExcludedDraft = ""
    @Published private(set) var hotKey = HotKeyCombo.load()
    @Published private(set) var isRecordingHotKey = false
    @Published private(set) var hotKeyError: String?
    /// 단축키를 시스템에 등록한다(nil이면 해제). 성공하면 참. AppDelegate가 채운다.
    var registerHotKey: ((HotKeyCombo?) -> Bool)?
    private var recordingMonitor: Any?

    private(set) var results: [Int32] = []
    private(set) var resultsEpoch: UInt64 = 0
    private(set) var sortKey: SortKey = .name
    private(set) var ascending = true

    weak var searchField: NSSearchField?
    weak var tableView: NSTableView?

    private let searchQueue = DispatchQueue(label: "allspot.search", qos: .userInitiated)
    private var currentCancel: CancelToken?
    private var searchSequence = 0
    private var lastSearchAt = Date.distantPast
    private var refreshScheduled = false
    /// 아직 끝나지 않은 검색(색인이 바뀌었다고 이걸 끊으면 Spotlight 질의가 영영 끝나지 않을 수 있다)
    private var searchInFlight = false
    private var refreshAfterSearch = false
    private var staleWhileHidden = false
    private var infoCache: [Int32: EntryInfo] = [:]
    private var folderSizes: [Int32: Int64] = [:]
    private var folderSizesPending = Set<Int32>()
    private var folderSizeCancel = CancelToken()
    private let folderSizeQueue = DispatchQueue(label: "allspot.folder-size", qos: .userInitiated)

    init() {
        controller = IndexController(configuration: Self.currentConfiguration())
        contentIndexer = ContentIndexer(fileIndex: controller.index)
        // 앱 묶음 안의 도우미(Helpers/allspot)가 있으면 문서 읽기를 맡겨 앱 메모리를 가볍게 둔다.
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/allspot")
        if FileManager.default.isExecutableFile(atPath: helper.path) { contentIndexer.workerURL = helper }
        externalSearcher = ExternalSearcher(content: contentIndexer.content)
    }

    /// 전체 디스크 접근 권한이 없으면 다른 앱의 데이터 폴더를 건너뛴다.
    /// 이 폴더를 열면 macOS가 "다른 앱의 데이터에 접근" 허용 창을 띄우고, 답할 때까지 훑기 전체가 멈춘다.
    /// 권한을 주면 저장본은 그대로 쓰고 이 폴더만 더 훑는다.
    static func currentConfiguration() -> IndexConfiguration {
        let excluded = UserDefaults.standard.stringArray(forKey: excludedPathsKey) ?? IndexConfiguration.defaultExcludedPaths
        var skipped: [String] = []
        if !fullDiskAccessGranted() {
            let library = NSHomeDirectory() + "/Library"
            skipped = [library + "/Containers", library + "/Group Containers", library + "/Daemon Containers"]
        }
        return IndexConfiguration(roots: ["/"], excludedPaths: excluded, skippedPaths: skipped)
    }

    /// TCC 데이터베이스는 전체 디스크 접근 권한이 있어야 열린다. 권한 확인용으로만 열고 바로 닫는다.
    nonisolated static func fullDiskAccessGranted() -> Bool {
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    func start() {
        controller.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexStatus = status
                // 이름 색인이 준비되면 한글 문서 내용 색인을 따라잡는다.
                if case .ready = status { self.contentIndexer.start() }
            }
        }
        controller.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.indexDidChange()
                self?.contentIndexer.scheduleReconcile()
            }
        }
        contentIndexer.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.contentStatus = status }
        }
        configureContentIndexer()
        controller.start()
        checkFullDiskAccess()
        let center = NotificationCenter.default
        for name in [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.staleWhileHidden else { return }
                    self.staleWhileHidden = false
                    self.indexDidChange()
                }
            }
        }
        // Everything의 -s 처럼 실행할 때 검색어를 넘길 수 있다: Allspot -s "보고서 *.hwp"
        // -s를 여러 번 주면 앞의 것들은 결과 내 검색 단계가 된다: Allspot -s 보고서 -s 2026
        let arguments = CommandLine.arguments
        var searches: [String] = []
        for (i, argument) in arguments.enumerated() where (argument == "-s" || argument == "--search") && i + 1 < arguments.count {
            searches.append(arguments[i + 1])
        }
        if let last = searches.popLast() {
            refinements = searches.map { Refinement(text: $0, fuzzy: fuzzyMode, count: 0) }
            query = last
            if query.isEmpty { runSearch() }
        }
    }

    // MARK: - 검색

    func runSearch() {
        currentCancel?.cancel()
        let token = CancelToken()
        currentCancel = token
        searchSequence += 1
        let sequence = searchSequence
        let segments = refinements.map { ($0.text, $0.fuzzy) } + [(query, fuzzyMode)]
        let sort = sortKey, ascending = ascending
        let index = controller.index
        let ownContentIndex = indexDocumentContents
        lastSearchAt = Date()
        searchInFlight = true
        refreshAfterSearch = false
        searchQueue.async { [weak self] in
            var begun = Date()
            let compiled: CompiledQuery
            do {
                compiled = try CompiledQuery.compile(segments: segments)
            } catch {
                DispatchQueue.main.async {
                    guard let self, sequence == self.searchSequence else { return }
                    self.queryError = "\(error)"
                    self.isSearchingOutside = false
                    self.finishSearch()
                }
                return
            }
            // 결과를 화면에 올린다. final이 거짓이면 Spotlight 답을 기다리는 중간 결과다.
            func publish(_ outcome: SearchOutcome, final: Bool) {
                DispatchQueue.main.async {
                    guard let self, sequence == self.searchSequence else { return }
                    self.queryError = nil
                    self.isSearchingOutside = !final
                    self.results = outcome.ids
                    self.resultsEpoch = outcome.epoch
                    self.resultCount = outcome.ids.count
                    // Spotlight에서 구해 온 시간까지 넣어야 색인 변경 때 다시 검색하는 간격이 알맞게 벌어진다.
                    self.searchMillis = Date().timeIntervalSince(begun) * 1000
                    self.infoCache.removeAll(keepingCapacity: true)
                    self.resetFolderSizes()
                    self.resultsVersion += 1
                    if final { self.finishSearch() }
                }
            }
            var external: [[ExternalMatch]] = []
            if !compiled.externalTerms.isEmpty {
                // Spotlight에 묻는 건 무거우므로 글자를 치는 동안은 잠깐 기다렸다가 마지막 것만 묻는다.
                Thread.sleep(forTimeInterval: 0.25)
                begun = Date()
                guard !token.isCancelled, let self else { return }
                DispatchQueue.main.async { if sequence == self.searchSequence { self.isSearchingOutside = true } }
                let searcher = self.externalSearcher
                // 내용·작성자 조건이면 자체 색인 답부터 바로 보여 주고, Spotlight 답이 오면 더한다.
                if ownContentIndex, compiled.externalTerms.allSatisfy(ExternalSearcher.isLocal),
                   !compiled.externalTerms.allSatisfy(searcher.hasCachedSpotlight) {
                    let local = compiled.externalTerms.map { searcher.matches(for: $0, cancel: token, spotlight: false) }
                    guard !token.isCancelled else { return }
                    let early = index.search(compiled, sort: sort, ascending: ascending, cancel: token, external: local)
                    guard !early.cancelled else { return }
                    publish(early, final: false)
                }
                external = compiled.externalTerms.map { searcher.matches(for: $0, cancel: token) }
                guard !token.isCancelled else { return }
            }
            let outcome = index.search(compiled, sort: sort, ascending: ascending, cancel: token, external: external)
            guard !outcome.cancelled else { return }
            publish(outcome, final: true)
        }
    }

    // MARK: - 결과 내 검색

    var canRefine: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && queryError == nil
    }

    /// 지금 검색어를 고정하고 검색창을 비운다. 이어 치는 검색어는 지금 결과 안에서만 찾는다.
    func refineWithinResults() {
        guard canRefine else { return }
        refinements.append(Refinement(text: query, fuzzy: fuzzyMode, count: resultCount))
        query = ""
        focusSearch(selectAll: false)
    }

    func removeRefinement(_ refinement: Refinement) {
        refinements.removeAll { $0.id == refinement.id }
        runSearch()
    }

    /// 검색창이 비었을 때 ⌫: 마지막 단계를 검색창으로 되돌려 고칠 수 있게 한다.
    func popRefinement() {
        guard let last = refinements.popLast() else { return }
        if query == last.text { runSearch() } else { query = last.text }
    }

    func clearRefinements() {
        guard !refinements.isEmpty else { return }
        refinements.removeAll()
        runSearch()
    }

    /// 검색어를 최근 목록 맨 앞에 넣는다(같은 것은 하나만, 20개까지).
    func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recentQueries.removeAll { $0 == trimmed }
        recentQueries.insert(trimmed, at: 0)
        if recentQueries.count > 20 { recentQueries.removeLast(recentQueries.count - 20) }
        UserDefaults.standard.set(recentQueries, forKey: Self.recentQueriesKey)
    }

    // MARK: - 즐겨찾기

    /// 지금 화면의 검색(결과 내 검색 단계 포함). 비었으면 nil.
    var currentBookmark: Bookmark? {
        let stages = refinements.map(\.text) + [query.trimmingCharacters(in: .whitespaces)]
        let kept = stages.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : Bookmark(stages: kept, fuzzy: fuzzyMode)
    }

    var isCurrentBookmarked: Bool { currentBookmark.map(bookmarks.contains) ?? false }

    /// 지금 검색을 즐겨찾기에 넣거나, 이미 있으면 뺀다.
    func toggleCurrentBookmark() {
        guard let current = currentBookmark else { return }
        if let i = bookmarks.firstIndex(of: current) { bookmarks.remove(at: i) } else { bookmarks.append(current) }
        saveBookmarks()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0 == bookmark }
        saveBookmarks()
    }

    func openBookmark(_ bookmark: Bookmark) {
        guard let last = bookmark.stages.last else { return }
        if fuzzyMode != bookmark.fuzzy { fuzzyMode = bookmark.fuzzy }
        refinements = bookmark.stages.dropLast().map { Refinement(text: $0, fuzzy: bookmark.fuzzy, count: 0) }
        if query == last { runSearch() } else { query = last }
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: Self.bookmarksKey) }
    }

    func clearRecentQueries() {
        recentQueries = []
        UserDefaults.standard.removeObject(forKey: Self.recentQueriesKey)
    }

    private func finishSearch() {
        recordRecent?.cancel()
        if resultCount > 0 && refinements.isEmpty {
            // 글자를 치는 중간 단계는 남기지 않도록, 결과를 1.5초 넘게 본 검색어만 기록한다.
            let text = query
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.query == text else { return }
                self.remember(text)
            }
            recordRecent = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
        searchInFlight = false
        if refreshAfterSearch {
            refreshAfterSearch = false
            indexDidChange()
        }
    }

    /// 색인이 바뀌면 지금 검색을 다시 돌린다. 너무 잦지 않게 묶고,
    /// 검색이 무거울수록(결과 수백만 개 등) 간격을 넓혀 CPU를 계속 쓰지 않게 한다.
    private func indexDidChange() {
        // 창이 안 보이면 다시 검색하지 않고, 창이 보일 때 한 번만 한다.
        guard let window = searchField?.window, window.isVisible, window.occlusionState.contains(.visible), !NSApp.isHidden else {
            staleWhileHidden = true
            return
        }
        // 검색이 아직 돌고 있으면 끝난 뒤에 한 번만 다시 한다.
        if searchInFlight {
            refreshAfterSearch = true
            return
        }
        let interval = max(isIndexing ? 3.0 : 1.0, searchMillis / 1000 * 10)
        let wait = interval - Date().timeIntervalSince(lastSearchAt)
        if wait <= 0 {
            runSearch()
        } else if !refreshScheduled {
            refreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.refreshScheduled = false
                self?.runSearch()
            }
        }
    }

    func setSort(_ key: SortKey, ascending: Bool) {
        guard key != sortKey || ascending != self.ascending else { return }
        sortKey = key
        self.ascending = ascending
        runSearch()
    }

    /// 폴더 크기 합계(뒤에서 계산해 기억해 둔다). 아직 모르면 nil을 주고, 다 세면 그 줄을 다시 그린다.
    func folderSize(row: Int, id: Int32) -> Int64? {
        if let size = folderSizes[id] { return size }
        guard !folderSizesPending.contains(id) else { return nil }
        folderSizesPending.insert(id)
        let index = controller.index, epoch = resultsEpoch, version = resultsVersion
        let cancel = folderSizeCancel
        folderSizeQueue.async { [weak self] in
            let size = index.folderSize(id, epoch: epoch, cancel: cancel)
            DispatchQueue.main.async {
                guard let self, let size, version == self.resultsVersion else { return }
                self.folderSizes[id] = size
                self.folderSizesPending.remove(id)
                if row < self.results.count, self.results[row] == id {
                    self.tableView?.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<(self.tableView?.numberOfColumns ?? 0)))
                }
            }
        }
        return nil
    }

    /// 결과가 바뀌면 폴더 크기 계산을 버린다.
    private func resetFolderSizes() {
        folderSizeCancel.cancel()
        folderSizeCancel = CancelToken()
        folderSizes.removeAll(keepingCapacity: true)
        folderSizesPending.removeAll(keepingCapacity: true)
    }

    func info(row: Int) -> EntryInfo? {
        guard row >= 0, row < results.count else { return nil }
        let id = results[row]
        if let cached = infoCache[id] { return cached }
        guard let info = controller.index.info(id, epoch: resultsEpoch) else { return nil }
        if infoCache.count > 4000 { infoCache.removeAll(keepingCapacity: true) }
        infoCache[id] = info
        return info
    }

    private func configureContentIndexer() {
        contentIndexer.configure(enabled: indexDocumentContents, includeCloud: includeCloudDocuments)
    }

    func rebuildIndex() {
        controller.rebuild(configuration: Self.currentConfiguration())
    }

    // MARK: - 전역 단축키

    @discardableResult
    func applyHotKey(_ combo: HotKeyCombo) -> Bool {
        guard registerHotKey?(combo) == true else {
            hotKeyError = "\(combo.display)는 다른 앱이나 시스템이 이미 쓰고 있어요. 다른 조합을 눌러 주세요."
            return false
        }
        hotKeyError = nil
        hotKey = combo
        combo.save()
        return true
    }

    /// 다음에 누르는 키 조합을 새 단축키로 받는다. Esc는 취소.
    func startRecordingHotKey() {
        guard !isRecordingHotKey else { return }
        isRecordingHotKey = true
        hotKeyError = nil
        _ = registerHotKey?(nil) // 받는 동안 지금 단축키가 창을 숨기지 않게 잠시 해제
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent는 Sendable이 아니라서 주 스레드 쪽으로는 키 값만 넘기고, 먹었는지 여부만 돌려받는다.
            let isEscape = event.keyCode == 53
            let combo = HotKeyCombo(event: event)
            let consumed: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                if isEscape {
                    self.stopRecordingHotKey()
                    _ = self.registerHotKey?(self.hotKey)
                    return true
                }
                guard let combo else {
                    self.hotKeyError = "⌘, ⌥, ⌃ 중 하나와 함께 눌러 주세요(F1~F19는 혼자도 돼요)."
                    return true
                }
                self.stopRecordingHotKey()
                if !self.applyHotKey(combo) {
                    _ = self.registerHotKey?(self.hotKey)
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    func stopRecordingHotKey() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        isRecordingHotKey = false
    }

    func resetHotKey() {
        stopRecordingHotKey()
        applyHotKey(.standard)
    }

    // MARK: - 상태 글

    var statusLine: String {
        switch indexStatus {
        case .starting: return "준비 중…"
        case .loadingCache: return "저장된 색인 불러오는 중…"
        case .scanning(let n): return "디스크 훑는 중… \(n.formatted())개"
        case .ready(let n): return "색인 \(n.formatted())개 · 실시간 반영 중"
        }
    }

    /// 상태 줄에 보일 문서 내용 색인 진행(진행 중일 때만)
    var contentStatusLine: String? {
        guard indexDocumentContents, contentStatus.isRunning, contentStatus.total > 0 else { return nil }
        return "문서 내용 읽는 중 \(contentStatus.indexed.formatted())/\(contentStatus.total.formatted())"
    }

    var isIndexing: Bool {
        if case .scanning = indexStatus { return true }
        if case .loadingCache = indexStatus { return true }
        return false
    }

    // MARK: - 전체 디스크 접근 권한

    func checkFullDiskAccess() {
        hasFullDiskAccess = Self.fullDiskAccessGranted()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 포커스

    func focusSearch(selectAll: Bool) {
        guard let field = searchField, let window = field.window else { return }
        window.makeFirstResponder(field)
        if selectAll { field.currentEditor()?.selectAll(nil) }
    }

    func focusResults() {
        guard let table = tableView, results.count > 0 else { return }
        table.window?.makeFirstResponder(table)
        if table.selectedRow < 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        table.scrollRowToVisible(max(table.selectedRow, 0))
    }

    // MARK: - 파일 작업

    func urls(rows: IndexSet) -> [URL] {
        rows.compactMap { info(row: $0) }.map { URL(fileURLWithPath: $0.fullPath) }
    }

    func open(rows: IndexSet) {
        for url in urls(rows: rows) { NSWorkspace.shared.open(url) }
    }

    /// 검색창에서 엔터: 선택한 줄(없으면 첫 줄)을 연다.
    func openSelectedOrFirst() {
        let selected = tableView?.selectedRowIndexes ?? []
        open(rows: selected.isEmpty ? (results.isEmpty ? [] : [0]) : selected)
    }

    func reveal(rows: IndexSet) {
        let list = urls(rows: rows)
        if !list.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(list) }
    }

    func copyPaths(rows: IndexSet) {
        let paths = urls(rows: rows).map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func copyNames(rows: IndexSet) {
        let names = rows.compactMap { info(row: $0)?.name }
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    func moveToTrash(rows: IndexSet) {
        let list = urls(rows: rows)
        guard !list.isEmpty else { return }
        NSWorkspace.shared.recycle(list) { _, error in
            if let error { NSLog("Allspot: 휴지통으로 옮기지 못함 \(error)") }
        }
    }
}
