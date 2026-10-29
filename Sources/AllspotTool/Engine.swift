import AllspotCore
import Darwin
import Foundation

/// AI 도구에 돌려줄 오류(사람이 읽을 문장)
struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 앱이 저장한 색인을 읽기 전용으로 열어 검색·본문 읽기를 해 준다(CLI와 MCP가 함께 쓴다).
/// 색인은 비춰 읽고(mmap) 저장 시점 이후 바뀐 것은 FSEvents 기록으로 따라잡으므로, 앱이 꺼져 있어도 최신에 가깝다.
final class Engine {
    static let maxLimit = 1_000
    static let maxChars = 200_000
    /// 결과 개수를 세며 훑는 최대 항목 수(숨긴 것을 빼고 세야 하므로 끝까지 볼 때가 있다)
    static let countCap = 100_000

    let controller: IndexController
    let content = ContentIndex()
    let external: ExternalSearcher
    let policy = AIAccessPolicy.fromAppSettings()
    private var contentStamp: timespec?

    var index: FileIndex { controller.index }

    init() {
        // 이 프로세스는 클라우드 전용 파일을 실수로 내려받지 않는다(본문 읽기에서 따로 허락할 때만).
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        controller = IndexController(configuration: IndexController.appConfiguration(), readOnly: true)
        external = ExternalSearcher(content: content)
        controller.start()
        reloadContentIfChanged()
    }

    /// 앱이 내용 색인을 다시 저장했으면 새로 읽는다.
    func reloadContentIfChanged() {
        var st = stat()
        guard stat(ContentIndexer.defaultCacheURL.path, &st) == 0 else { return }
        if let contentStamp, contentStamp.tv_sec == st.st_mtimespec.tv_sec, contentStamp.tv_nsec == st.st_mtimespec.tv_nsec { return }
        if content.load(from: ContentIndexer.defaultCacheURL) { contentStamp = st.st_mtimespec }
    }

    /// 거짓이면 저장본만 보고 바로 답한다(마지막 저장 뒤 몇 분 사이의 변경은 빠질 수 있다).
    var catchUp = true

    private func ready() throws {
        controller.waitUntilLoaded(timeout: 30)
        controller.waitUntilCaughtUp(timeout: catchUp ? 5 : 0)
        if controller.cacheMissing {
            throw ToolError("색인 저장본이 없습니다. Allspot 앱을 한 번 실행해 색인을 만든 뒤 다시 시도하세요.")
        }
        reloadContentIfChanged()
    }

    // MARK: - 검색

    func search(_ text: String, limit: Int = 50, offset: Int = 0, sort: SortKey = .name, descending: Bool = false,
                fuzzy: Bool = false, spotlight: Bool = true) throws -> [String: Any] {
        try ready()
        let started = Date()
        let query: CompiledQuery
        do {
            query = try CompiledQuery.compile(text, fuzzy: fuzzy)
        } catch {
            throw ToolError("검색어를 이해하지 못했습니다: \(error)")
        }
        let matches = query.externalTerms.map { external.matches(for: $0, cancel: nil, spotlight: spotlight) }
        let outcome = index.search(query, sort: sort, ascending: !descending, external: matches)
        let limit = max(1, min(limit, Self.maxLimit))
        let offset = max(0, offset)
        // 숨긴 위치의 항목은 결과에도 개수에도 넣지 않는다(개수로 숨긴 문서의 내용을 떠볼 수 없게).
        var results: [[String: Any]] = []
        var total = 0
        var scanned = 0
        for id in outcome.ids {
            if scanned >= Self.countCap && results.count >= limit { break }
            scanned += 1
            guard let info = index.info(id, epoch: outcome.epoch) else { continue }
            let path = info.fullPath
            guard policy.allows(path), !AIAccessPolicy.isSecret(path) else { continue }
            if total >= offset && results.count < limit { results.append(Self.describe(info, path: path)) }
            total += 1
        }
        let complete = scanned >= outcome.ids.count
        var response: [String: Any] = [
            "query": text,
            "total_matches": total,
            "offset": offset,
            "returned": results.count,
            "results": results,
            "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000),
        ]
        if !complete { response["total_is_lower_bound"] = true }
        if offset + results.count < total || !complete { response["next_offset"] = offset + results.count }
        return response
    }

    static func describe(_ info: EntryInfo, path: String) -> [String: Any] {
        var item: [String: Any] = [
            "path": path,
            "name": info.name,
            "type": info.isDirectory ? "folder" : "file",
            "modified": iso(info.modified),
        ]
        if !info.isDirectory { item["size"] = info.size }
        if isCloudOnly(path) { item["cloud_only"] = true }
        return item
    }

    // MARK: - 본문

    func text(_ rawPath: String, offset: Int = 0, maxChars: Int = 20_000, allowDownload: Bool = false) throws -> [String: Any] {
        let path = try checkedPath(rawPath)
        if AIAccessPolicy.isSecret(path) {
            throw ToolError("비밀 정보가 들었을 수 있는 파일이라 내용을 읽지 않습니다: \(path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw ToolError("파일이 없습니다: \(path)") }
        if isDirectory.boolValue { throw ToolError("폴더입니다. search_files로 안의 파일을 찾으세요: \(path)") }
        let cloudOnly = Self.isCloudOnly(path)
        if cloudOnly && !allowDownload {
            throw ToolError("클라우드에만 있는 파일입니다. 읽으면 내려받게 되므로 사용자가 허락한 경우에만 allow_download를 켜세요: \(path)")
        }
        guard let extracted = try TextWorker.run(path: path, download: cloudOnly) else {
            let kinds = (DocumentText.indexedExtensions.union(DocumentText.plainExtensions)).sorted().joined(separator: ", ")
            throw ToolError("이 파일의 본문을 읽지 못했습니다(지원 형식: \(kinds); 암호가 걸렸거나 손상된 파일일 수 있음): \(path)")
        }
        let body = extracted.text
        let total = body.count
        let maxChars = max(1, min(maxChars, Self.maxChars))
        let offset = min(max(0, offset), total)
        let start = body.index(body.startIndex, offsetBy: offset, limitedBy: body.endIndex) ?? body.endIndex
        let end = body.index(start, offsetBy: maxChars, limitedBy: body.endIndex) ?? body.endIndex
        let slice = String(body[start..<end])
        var response: [String: Any] = [
            "path": path,
            "format": (path as NSString).pathExtension.lowercased(),
            "total_chars": total,
            "offset": offset,
            "returned_chars": slice.count,
            "text": slice,
        ]
        if let author = extracted.author { response["author"] = author }
        if end < body.endIndex { response["next_offset"] = offset + slice.count }
        return response
    }

    // MARK: - 정보·상태

    func info(_ rawPath: String) throws -> [String: Any] {
        let path = try checkedPath(rawPath)
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ToolError("파일이 없습니다: \(path)") }
        let isDirectory = st.st_mode & S_IFMT == S_IFDIR
        var item: [String: Any] = [
            "path": path,
            "name": (path as NSString).lastPathComponent,
            "type": isDirectory ? "folder" : (st.st_mode & S_IFMT == S_IFLNK ? "symlink" : "file"),
            "modified": Self.iso(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))),
            "created": Self.iso(Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))),
            "cloud_only": st.st_flags & UInt32(SF_DATALESS) != 0,
            "in_name_index": index.lookup(path) != nil,
        ]
        if !isDirectory {
            item["size"] = Int64(st.st_size)
            item["content_indexed"] = content.contains(path)
            item["readable_text"] = !AIAccessPolicy.isSecret(path) &&
                DocumentText.indexedExtensions.union(DocumentText.plainExtensions).contains((path as NSString).pathExtension.lowercased())
        }
        return item
    }

    func status() -> [String: Any] {
        controller.waitUntilCaughtUp(timeout: 5)
        reloadContentIfChanged()
        var response: [String: Any] = [
            "name_index_entries": index.liveCount,
            "name_index_loaded": !controller.cacheMissing,
            "caught_up_with_file_changes": controller.waitUntilCaughtUp(timeout: 0),
            "content_documents": content.count,
            "content_text_mb": Double(content.textBytes / 10_485) / 100,
            "content_extensions": DocumentText.indexedExtensions.sorted(),
            "ai_excluded_paths": policy.excludedPaths,
        ]
        if let saved = Self.modified(IndexController.defaultCacheURL.path) { response["name_index_saved"] = Self.iso(saved) }
        if let saved = Self.modified(ContentIndexer.defaultCacheURL.path) { response["content_index_saved"] = Self.iso(saved) }
        return response
    }

    // MARK: - 도우미

    /// ~를 풀고 실제 위치로 맞춘 절대 경로. AI에게 숨기는 위치면 거절한다.
    /// 같은 파일을 가리키는 다른 이름(/System/Volumes/Data/…, /.vol/장치/아이노드, 대소문자, 심볼릭 링크)으로
    /// 규칙을 비켜 가지 못하게, 파일을 열어 커널이 아는 경로(F_GETPATH)로 판정한다.
    private func checkedPath(_ raw: String) throws -> String {
        try Self.checkedPath(raw, policy: policy)
    }

    /// 숨긴 곳이면 파일을 열어 보기 전에 거절하고, 오류에는 받은 그대로의 경로만 쓴다(실제 이름으로 있는지 없는지 떠볼 수 없게).
    static func checkedPath(_ raw: String, policy: AIAccessPolicy) throws -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
        guard path.hasPrefix("/") else { throw ToolError("절대 경로를 주세요(예: /Users/이름/Documents/a.pdf): \(raw)") }
        path = (path as NSString).standardizingPath
        let lower = path.lowercased()
        if lower == "/.vol" || lower.hasPrefix("/.vol/") || lower.hasPrefix("/dev/") {
            throw ToolError("이 경로 형식은 쓸 수 없습니다: \(raw)")
        }
        let denied = ToolError("AI 접근에서 빼 둔 위치입니다: \(raw)")
        guard policy.allows(path) else { throw denied }
        if let real = kernelPath(path) {
            path = real
        } else if let resolved = realpath(path, nil) {
            path = String(cString: resolved)
            free(resolved)
        }
        path = AIAccessPolicy.stripDataVolume(path)
        if path.lowercased().hasPrefix("/system/volumes/") { throw ToolError("시스템 볼륨 경로는 쓸 수 없습니다: \(raw)") }
        guard policy.allows(path) else { throw denied }
        return path
    }

    /// 보통 파일·폴더를 열어 커널이 아는 경로를 얻는다(장치·파이프는 열지 않는다).
    static func kernelPath(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG || st.st_mode & S_IFMT == S_IFDIR else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func isCloudOnly(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0
    }

    static func modified(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// [String: Any]를 JSON 한 줄(또는 보기 좋게)로
func jsonString(_ object: Any, pretty: Bool = false) -> String {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
