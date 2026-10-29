import AllspotCore
import Foundation

// 사용법:
//   allspot-cli bench <폴더> [검색어...]   폴더를 훑고 검색 속도를 잰다(저장·불러오기 왕복도 확인)
//   allspot-cli watch <폴더>              파일을 만들고 지우며 실시간 반영을 확인한다
//   allspot-cli fuzzy <빈 폴더>           유사 검색·초성·결과 내 검색을 확인한다
//   allspot-cli cache [검색어...]         앱이 저장한 실제 색인으로 일반·유사 검색 속도를 잰다
//   allspot-cli list <검색어>             앱이 저장한 실제 색인에서 찾은 전체 경로를 찍는다
//   allspot-cli content [검색어...]       실제 색인으로 문서 내용 색인을 만들고 content:·tag: 등을 시험한다
//   allspot-cli docs                      형식마다 시험 문서를 만들어 본문 꺼내기·비밀 파일·후보 규칙을 확인한다
//   allspot-cli worker <도우미> <문서...>  문서 읽기 도우미가 죽거나 엉뚱한 것을 내보내도 버티는지 확인한다

func printResults(_ index: FileIndex, _ outcome: SearchOutcome, limit: Int = 8) {
    for id in outcome.ids.prefix(limit) {
        if let info = index.info(id, epoch: outcome.epoch) { print("   \(info.isDirectory ? "📁" : "  ") \(info.fullPath)") }
    }
}

func run(_ index: FileIndex, _ text: String, sort: SortKey = .name) -> SearchOutcome? {
    do {
        let query = try CompiledQuery.compile(text)
        let outcome = index.search(query, sort: sort)
        print(String(format: "검색 %-28@ %9d개  %7.1f ms", "\"\(text)\"" as NSString, outcome.ids.count, outcome.elapsed * 1000))
        return outcome
    } catch {
        print("검색 \"\(text)\" 오류: \(error)")
        return nil
    }
}

func bench(_ root: String, _ queries: [String]) {
    let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("allspot-bench-\(getpid()).bin")
    let configuration = IndexConfiguration(roots: [root], excludedPaths: IndexConfiguration.defaultExcludedPaths)
    let controller = IndexController(configuration: configuration, cacheURL: cache)
    let done = DispatchSemaphore(value: 0)
    let started = Date()
    controller.onStatus = { status in
        if case .ready(let n) = status {
            print(String(format: "색인 완료: %d개, %.2f초", n, Date().timeIntervalSince(started)))
            done.signal()
        }
    }
    controller.start()
    done.wait()
    let index = controller.index
    let queries = queries.isEmpty ? ["", "a", "readme", "*.pdf", "ext:jpg;png", "size:>100mb", "dm:today", "users/ swift", "!e", "regex:^img_\\d+"] : queries
    for q in queries {
        if let outcome = run(index, q) { printResults(index, outcome, limit: 3) }
    }
    for sort in [SortKey.path, .size, .modified] {
        _ = run(index, "a", sort: sort)
    }
    controller.save(wait: true)
    let reloaded = FileIndex()
    let t = Date()
    let eventId = reloaded.load(from: cache, expectedConfigHash: configuration.stableHash)
    print(String(format: "저장본 불러오기: %@, %d개, %.0f ms", eventId != nil ? "성공" : "실패", reloaded.liveCount, Date().timeIntervalSince(t) * 1000))
    if let a = run(index, "readme"), let b = run(reloaded, "readme") {
        print("불러온 색인 결과 일치: \(a.ids.count == b.ids.count ? "예" : "아니오 \(a.ids.count) vs \(b.ids.count)")")
    }
    try? FileManager.default.removeItem(at: cache)
}

/// 앱이 저장한 실제 색인을 불러와 검색 속도를 잰다. 각 검색어는 일반·유사 두 가지로 잰다.
func cacheBench(_ queries: [String]) {
    let defaults = UserDefaults(suiteName: "com.techkwon.allspot")
    let excluded = defaults?.stringArray(forKey: "excludedPaths") ?? IndexConfiguration.defaultExcludedPaths
    let configuration = IndexConfiguration(roots: ["/"], excludedPaths: excluded)
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Allspot/index.v2.bin")
    let index = FileIndex()
    guard index.load(from: cache, expectedConfigHash: configuration.stableHash) != nil else {
        print("저장본을 불러오지 못함: \(cache.path)")
        return
    }
    print("저장본 \(index.liveCount)개")
    for q in queries {
        for fuzzy in [false, true] {
            guard let query = try? CompiledQuery.compile(q, fuzzy: fuzzy) else { continue }
            var best = Double.infinity
            var count = 0
            for _ in 0..<3 {
                let outcome = index.search(query)
                best = min(best, outcome.elapsed * 1000)
                count = outcome.ids.count
            }
            print(String(format: "%@ %-20@ %8d개  %7.1f ms", fuzzy ? "유사" : "일반", "\"\(q)\"" as NSString, count, best))
        }
    }
}

/// 앱이 저장한 실제 색인에서 검색해 전체 경로를 한 줄에 하나씩 찍는다.
func cacheList(_ text: String) {
    let defaults = UserDefaults(suiteName: "com.techkwon.allspot")
    let excluded = defaults?.stringArray(forKey: "excludedPaths") ?? IndexConfiguration.defaultExcludedPaths
    let configuration = IndexConfiguration(roots: ["/"], excludedPaths: excluded)
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Allspot/index.v2.bin")
    let index = FileIndex()
    guard index.load(from: cache, expectedConfigHash: configuration.stableHash) != nil,
          let query = try? CompiledQuery.compile(text) else { return }
    let outcome = index.search(query)
    for id in outcome.ids {
        if let info = index.info(id, epoch: outcome.epoch) { print(info.fullPath) }
    }
}

/// 앱이 저장한 실제 색인으로 한글 문서 내용 색인을 (임시 저장본에) 만들고, 내용·메타데이터 검색을 해 본다.
func cacheContent(_ queries: [String]) {
    let defaults = UserDefaults(suiteName: "com.techkwon.allspot")
    let excluded = defaults?.stringArray(forKey: "excludedPaths") ?? IndexConfiguration.defaultExcludedPaths
    let configuration = IndexConfiguration(roots: ["/"], excludedPaths: excluded)
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Allspot/index.v2.bin")
    let index = FileIndex()
    guard index.load(from: cache, expectedConfigHash: configuration.stableHash) != nil else { return }
    let contentCache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("allspot-content-test.bin")
    let indexer = ContentIndexer(fileIndex: index, cacheURL: contentCache)
    let started = Date()
    indexer.onStatus = { status in
        if !status.isRunning {
            print(String(format: "내용 색인: %d/%d개, 클라우드 전용 %d개 건너뜀 (%.1f초)", status.indexed, status.total, status.cloudSkipped, Date().timeIntervalSince(started)))
        }
    }
    indexer.start()
    indexer.waitUntilIdle()
    let searcher = ExternalSearcher(content: indexer.content)
    for text in queries {
        do {
            let query = try CompiledQuery.compile(text)
            let t = Date()
            let external = query.externalTerms.map { searcher.matches(for: $0, cancel: nil) }
            let outcome = index.search(query, external: external)
            print(String(format: "검색 %-30@ %7d개  %7.1f ms (밖에서 구한 경로 %@)", "\"\(text)\"" as NSString, outcome.ids.count,
                         Date().timeIntervalSince(t) * 1000, external.map { String($0.reduce(0) { $0 + $1.paths.count }) }.joined(separator: ", ")))
            printResults(index, outcome, limit: 3)
        } catch {
            print("검색 \"\(text)\" 오류: \(error)")
        }
    }
}

func watch(_ root: String) {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().appendingPathComponent("allspot-watch-\(getpid())")
    try? fm.createDirectory(at: base.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
    fm.createFile(atPath: base.appendingPathComponent("sub/" + "첫번째파일.txt".decomposedStringWithCanonicalMapping).path, contents: Data("x".utf8))
    // 저장본을 쓰게 해서, 저장 뒤 파일을 비춰 쓰는 색인에서도 실시간 반영이 되는지 본다.
    let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("allspot-watch-\(getpid()).bin")
    defer { try? fm.removeItem(at: cache) }
    let controller = IndexController(configuration: IndexConfiguration(roots: [base.path], excludedPaths: []), cacheURL: cache)
    let ready = DispatchSemaphore(value: 0)
    controller.onStatus = { if case .ready = $0 { ready.signal() } }
    controller.start()
    ready.wait()
    controller.save(wait: true)
    let index = controller.index

    func expect(_ query: String, _ count: Int, _ label: String) -> Bool {
        for _ in 0..<40 {
            let outcome = index.search(try! CompiledQuery.compile(query))
            if outcome.ids.count == count { print("  ✓ \(label)"); return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let outcome = index.search(try! CompiledQuery.compile(query))
        print("  ✗ \(label): \"\(query)\" 결과 \(outcome.ids.count)개(기대 \(count)개)")
        return false
    }

    var ok = expect("첫번째", 1, "처음 훑기에서 한글(NFD/NFC) 파일 찾기")
    fm.createFile(atPath: base.appendingPathComponent("sub/deep/newfile-alpha.md").path, contents: Data())
    ok = expect("newfile-alpha", 1, "새 파일 생성 반영") && ok
    try? fm.createDirectory(at: base.appendingPathComponent("brand/new/dir"), withIntermediateDirectories: true)
    fm.createFile(atPath: base.appendingPathComponent("brand/new/dir/inside.txt").path, contents: Data())
    ok = expect("inside.txt", 1, "새 폴더 트리 반영") && ok
    try? fm.moveItem(at: base.appendingPathComponent("sub/deep/newfile-alpha.md"), to: base.appendingPathComponent("sub/renamed-beta.md"))
    ok = expect("newfile-alpha", 0, "이름 바꾼 옛 이름 사라짐") && ok
    ok = expect("renamed-beta", 1, "이름 바꾼 새 이름 나타남") && ok
    try? fm.removeItem(at: base.appendingPathComponent("brand"))
    ok = expect("inside.txt", 0, "폴더 삭제 반영") && ok
    ok = expect("path:sub/deep", 1, "경로 검색") && ok
    try? fm.removeItem(at: base)
    print(ok ? "실시간 반영 확인: 모두 통과" : "실시간 반영 확인: 실패 있음")
    exit(ok ? 0 : 1)
}

func fuzzyTest(_ root: String) {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: root).appendingPathComponent("allspot-fuzzy-\(getpid())")
    let names = ["report.pdf", "annual-report-2026.pdf", "rpt.txt", "보고서.hwp", "2026 학교 보고서 최종.hwpx", "보고 자료.txt",
                 "수업계획서.docx", "photo_IMG_1234.jpg", "README.md", "readme-old.txt", "Allspot.app", "spotlight.txt"]
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    for name in names {
        // 맥에서 흔한 NFD(자모 분리) 이름도 섞는다.
        let stored = name.hasPrefix("보고서") ? name.decomposedStringWithCanonicalMapping : name
        fm.createFile(atPath: base.appendingPathComponent(stored).path, contents: Data())
    }
    let controller = IndexController(configuration: IndexConfiguration(roots: [base.path], excludedPaths: []), cacheURL: nil)
    let ready = DispatchSemaphore(value: 0)
    controller.onStatus = { if case .ready = $0 { ready.signal() } }
    controller.start()
    ready.wait()
    let index = controller.index
    var ok = true
    func check(_ text: String, fuzzy: Bool, _ expected: [String], exact: Bool = false) {
        let query = try! CompiledQuery.compile(text, fuzzy: fuzzy)
        let outcome = index.search(query)
        let got = outcome.ids.compactMap { index.info($0, epoch: outcome.epoch)?.name.precomposedStringWithCanonicalMapping }
            .filter { !$0.hasPrefix("allspot-fuzzy") }
        let pass = exact ? got == expected : Array(got.prefix(expected.count)) == expected
        if !pass { ok = false }
        print("  \(pass ? "✓" : "✗") \(fuzzy ? "유사" : "일반") \"\(text)\" → \(got)")
    }
    check("ㅂㄱㅅ", fuzzy: false, ["보고서.hwp", "2026 학교 보고서 최종.hwpx"], exact: true)
    check("보ㄱㅅ", fuzzy: false, ["보고서.hwp", "2026 학교 보고서 최종.hwpx"], exact: true)
    check("repotr", fuzzy: true, ["report.pdf", "annual-report-2026.pdf"])
    check("rport", fuzzy: true, ["report.pdf", "annual-report-2026.pdf"])
    check("rptpdf", fuzzy: true, ["report.pdf"])
    check("보고소", fuzzy: true, ["보고서.hwp"])
    check("수업게획서", fuzzy: true, ["수업계획서.docx"])
    check("readme", fuzzy: true, ["README.md", "readme-old.txt"])
    check("~repotr ext:pdf", fuzzy: false, ["report.pdf", "annual-report-2026.pdf"], exact: true)
    check("repotr", fuzzy: false, [], exact: true)
    // 검색 내 검색: 앞 검색어와 새 검색어를 모두 만족
    let refined = try! CompiledQuery.compile(segments: [("report", false), ("2026", false)])
    let outcome = index.search(refined)
    let names2 = outcome.ids.compactMap { index.info($0, epoch: outcome.epoch)?.name }
    let refineOk = names2 == ["annual-report-2026.pdf"]
    if !refineOk { ok = false }
    print("  \(refineOk ? "✓" : "✗") 검색 내 검색 report → 2026 → \(names2)")
    try? fm.removeItem(at: base)
    print(ok ? "유사 검색 확인: 모두 통과" : "유사 검색 확인: 실패 있음")
    exit(ok ? 0 : 1)
}

let args = CommandLine.arguments
if args.count == 2 && args[1] == "docs" { docsTest() }
guard args.count >= 3 else {
    print("사용법: allspot-cli bench <폴더> [검색어...] | allspot-cli watch <폴더> | allspot-cli fuzzy <폴더> | allspot-cli docs")
    exit(2)
}
switch args[1] {
case "bench": bench(args[2], Array(args.dropFirst(3)))
case "watch": watch(args[2])
case "fuzzy": fuzzyTest(args[2])
case "cache": cacheBench(Array(args.dropFirst(2)))
case "list": cacheList(args[2])
case "content": cacheContent(Array(args.dropFirst(2)))
case "docs": docsTest()
case "worker":
    // 문서 읽기 도우미가 죽거나 엉뚱한 것을 내보내도 앱 쪽이 버티는지
    let paths = Array(args.dropFirst(3))
    for tool in ["/usr/bin/true", "/usr/bin/yes", args[2]] {
        let t = Date()
        let n = ContentWorker.run(worker: URL(fileURLWithPath: tool), paths: paths, includeCloud: false) { i, keys in
            print("  \(i): \(keys.map { "본문 \($0.body.count)바이트" } ?? "못 읽음")")
        }
        print("\(tool): \(n)/\(paths.count)개 받음, \(Int(Date().timeIntervalSince(t) * 1000))ms")
    }
default: print("알 수 없는 명령: \(args[1])"); exit(2)
}
