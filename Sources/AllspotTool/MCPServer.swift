import AllspotCore
import Foundation

/// MCP(Model Context Protocol) 서버: 표준 입출력으로 한 줄에 JSON-RPC 메시지 하나씩 주고받는다.
/// 로그는 표준 오류로만 쓴다(표준 출력은 프로토콜 전용).
final class MCPServer {
    static let version = "0.1.0"

    /// 만들 때 색인 저장본을 열고 변경 따라잡기를 시작한다(첫 도구 호출 전에 끝나 있도록).
    private let engine = Engine()

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return } // 응답(우리가 요청한 적 없음)은 무시
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "allspot", "version": Self.version],
                "instructions": Self.instructions,
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            result = call(params)
        default:
            if id != nil {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
            return
        }
        guard let id else { return } // 알림에는 답하지 않는다.
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func call(_ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        func int(_ key: String, _ fallback: Int) -> Int { (args[key] as? NSNumber)?.intValue ?? fallback }
        func bool(_ key: String) -> Bool { (args[key] as? NSNumber)?.boolValue ?? false }
        do {
            let output: [String: Any]
            switch name {
            case "search_files":
                guard let query = args["query"] as? String, !query.isEmpty else { throw ToolError("query가 필요합니다.") }
                let sort = SortKey(rawValue: args["sort"] as? String ?? "name") ?? .name
                output = try engine.search(query, limit: int("limit", 50), offset: int("offset", 0), sort: sort,
                                           descending: bool("descending"), fuzzy: bool("fuzzy"),
                                           spotlight: (args["include_spotlight"] as? NSNumber)?.boolValue ?? true)
            case "read_document_text":
                guard let path = args["path"] as? String else { throw ToolError("path가 필요합니다.") }
                output = try engine.text(path, offset: int("offset", 0), maxChars: int("max_chars", 20_000),
                                         allowDownload: bool("allow_download"))
            case "file_info":
                guard let path = args["path"] as? String else { throw ToolError("path가 필요합니다.") }
                output = try engine.info(path)
            case "index_status":
                output = engine.status()
            default:
                throw ToolError("알 수 없는 도구: \(name)")
            }
            return ["content": [["type": "text", "text": jsonString(output)]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    }

    private func send(_ object: [String: Any]) {
        let line = jsonString(object) + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    // MARK: - 도구 설명

    static let instructions = """
    Allspot searches every file and folder name on this Mac instantly (Everything-style index), plus document \
    contents (hwp, hwpx, pdf, docx, pptx, xlsx, txt, md) and Spotlight metadata. Use search_files first to find \
    candidates, then read_document_text to read one. Results never include folders the user excluded from AI access.
    """

    static let querySyntax = """
    Allspot query syntax (Everything-style). Space = AND, `a|b` = OR, `!word` = NOT, "exact phrase", wildcards `*.pdf`, \
    `IMG_????.jpg`. A term containing `/` matches the full path (`Downloads/ report`, `path:Documents/2026`). \
    Filters: `ext:pdf;docx`, `file:` / `folder:`, `size:>100mb`, `size:1mb..1gb`, `dm:today`, `dm:7d`, `dm:2026-05`, \
    `dm:>2026-01-01`, `kind:image|video|audio|doc|archive|code|folder`, `regex:^IMG_\\d+`, Korean initial consonants \
    (`ㅂㄱㅅ` matches 보고서), `~word` = typo-tolerant match for that word. Content and metadata: `content:예산` \
    (document text), `author:홍길동`, `tag:red` (Finder tag), `taken:2026-05` (photo/video capture date), \
    `spotlight:<raw MDQuery>`. Korean aliases work too (내용:, 작성자:, 태그:, 촬영:, 종류:). Example: \
    `content:"수업 나눔" ext:hwp;hwpx dm:2026` or `계획서 path:Documents`.
    """

    static var tools: [[String: Any]] {
        [
            [
                "name": "search_files",
                "description": "Search the whole Mac by file/folder name (instant, ~4M entries) and optionally by document content or metadata. Returns paths with size and modified time. " + querySyntax,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Allspot query, e.g. `보고서 ext:hwp dm:thisweek`"],
                        "limit": ["type": "integer", "description": "Max results (default 50, max 1000)", "minimum": 1, "maximum": Engine.maxLimit],
                        "offset": ["type": "integer", "description": "Skip this many results (paging; use next_offset)", "minimum": 0],
                        "sort": ["type": "string", "enum": ["name", "path", "size", "modified"], "description": "Sort key (default name; with fuzzy, name sort ranks by relevance)"],
                        "descending": ["type": "boolean", "description": "Sort descending, e.g. newest first with sort=modified"],
                        "fuzzy": ["type": "boolean", "description": "Typo-tolerant matching for every word"],
                        "include_spotlight": ["type": "boolean", "description": "For content:/author: also ask Spotlight (default true; ~1-2 s). Set false for an instant answer from Allspot's own index of hwp, hwpx, pdf, docx, pptx, xlsx, txt, md."],
                    ],
                    "required": ["query"],
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "read_document_text",
                "description": "Extract plain text from a document: hwp (HWP 5.x), hwpx, pdf, docx, pptx, xlsx, txt, md and other text files. Returns a slice; page through long documents with offset/next_offset. Files that are only in iCloud/Google Drive are refused unless allow_download is true (reading downloads them; only set it if the user agreed). Secret files (.env, keys) are refused.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path (from search_files)"],
                        "offset": ["type": "integer", "description": "Start at this character offset", "minimum": 0],
                        "max_chars": ["type": "integer", "description": "Max characters to return (default 20000, max 200000)", "minimum": 1, "maximum": Engine.maxChars],
                        "allow_download": ["type": "boolean", "description": "Allow downloading a cloud-only file to read it (default false)"],
                    ],
                    "required": ["path"],
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "file_info",
                "description": "Metadata for one path: type, size, created/modified time, whether it is cloud-only, and whether its text is in the content index.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Absolute path"]],
                    "required": ["path"],
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "index_status",
                "description": "How many entries/documents are indexed, when the indexes were saved, and which folders are hidden from AI.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
        ]
    }
}
