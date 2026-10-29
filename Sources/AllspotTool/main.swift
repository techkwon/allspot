import AllspotCore
import Foundation

// AI(와 사람)를 위한 Allspot 명령줄 도구. 결과는 기본으로 JSON 한 줄이다.
//   allspot search <검색어…> [--limit N] [--offset N] [--sort name|path|size|modified] [--desc] [--fuzzy] [--paths]
//   allspot text <경로> [--offset N] [--max-chars N] [--download] [--raw]
//   allspot info <경로>
//   allspot status
//   allspot mcp            MCP 서버(표준 입출력)

let usage = """
사용법:
  allspot search <검색어…> [--limit N] [--offset N] [--sort name|path|size|modified] [--desc] [--fuzzy] [--paths] [--quick] [--no-spotlight]
  allspot text <경로> [--offset N] [--max-chars N] [--download] [--raw]
  allspot info <경로>
  allspot status
  allspot mcp
공통: --pretty 보기 좋은 JSON
--no-spotlight: content:·author:를 자체 내용 색인에서만 찾는다(빠름, Spotlight만 아는 형식은 빠짐)
--quick: 앱이 저장한 색인만 보고 바로 답한다(기본은 저장 뒤 바뀐 파일까지 따라잡느라 1초 안팎 더 걸림)
검색 문법 예: 보고서 ext:hwp;hwpx dm:thisweek   content:예산 kind:doc   ㅂㄱㅅ   ~repotr
"""

/// 옵션(--이름 값)과 나머지 낱말을 가른다.
struct Arguments {
    var words: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    static let valued: Set<String> = ["limit", "offset", "sort", "max-chars"]

    init(_ raw: ArraySlice<String>) {
        var rest = raw[...]
        var literal = false
        while let arg = rest.popFirst() {
            if !literal && arg == "--" { literal = true; continue }
            if !literal && arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if Self.valued.contains(name), let value = rest.popFirst() { options[name] = value } else { flags.insert(name) }
            } else {
                words.append(arg)
            }
        }
    }

    func int(_ name: String, _ fallback: Int) -> Int { options[name].flatMap(Int.init) ?? fallback }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { fail(usage, code: 2) }
let command = argv[1]
let args = Arguments(argv.dropFirst(2))
let pretty = args.flags.contains("pretty")

func emit(_ object: [String: Any]) {
    print(jsonString(object, pretty: pretty))
}

do {
    switch command {
    case "search":
        guard !args.words.isEmpty else { fail("검색어를 주세요.\n" + usage, code: 2) }
        let engine = Engine()
        engine.catchUp = !args.flags.contains("quick")
        let response = try engine.search(args.words.joined(separator: " "), limit: args.int("limit", 50), offset: args.int("offset", 0),
                                         sort: SortKey(rawValue: args.options["sort"] ?? "name") ?? .name,
                                         descending: args.flags.contains("desc"), fuzzy: args.flags.contains("fuzzy"),
                                         spotlight: !args.flags.contains("no-spotlight"))
        if args.flags.contains("paths") {
            for item in response["results"] as? [[String: Any]] ?? [] { print(item["path"] as? String ?? "") }
        } else {
            emit(response)
        }
    case "text":
        guard let path = args.words.first else { fail("경로를 주세요.\n" + usage, code: 2) }
        let response = try Engine().text(path, offset: args.int("offset", 0), maxChars: args.int("max-chars", 20_000),
                                         allowDownload: args.flags.contains("download"))
        if args.flags.contains("raw") { print(response["text"] as? String ?? "") } else { emit(response) }
    case "info":
        guard let path = args.words.first else { fail("경로를 주세요.\n" + usage, code: 2) }
        emit(try Engine().info(path))
    case "status":
        emit(Engine().status())
    case "mcp":
        MCPServer().run()
    case "index-worker":
        // 앱이 문서 본문을 읽힐 때 띄우는 도우미(사람이 쓰는 명령이 아님)
        ContentWorker.serve(includeCloud: args.flags.contains("include-cloud"))
    case "text-worker":
        // 본문 읽기 도우미(사람이 쓰는 명령이 아님). 경로는 이미 검사된 것이다.
        guard let path = args.words.first else { fail("경로가 없습니다", code: 2) }
        TextWorker.serve(path: path, download: args.flags.contains("download"))
    case "help", "--help", "-h":
        print(usage)
    default:
        fail("알 수 없는 명령: \(command)\n" + usage, code: 2)
    }
} catch {
    emit(["error": "\(error)"])
    exit(1)
}
