import AllspotCore
import AppKit
import CoreText
import Foundation

// allspot-cli docs: 형식마다 시험 문서를 만들어 본문 꺼내기, 비밀 파일·후보 규칙이 맞는지 확인한다.

private var failures = 0

private func check(_ ok: Bool, _ label: String) {
    print("  \(ok ? "✓" : "✗") \(label)")
    if !ok { failures += 1 }
}

/// 폴더 안 파일들을 zip으로 묶는다(시스템 zip 사용).
private func zip(_ dir: URL, to out: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = dir
    process.arguments = ["-q", "-r", "-X", out.path, "."]
    try? process.run()
    process.waitUntilExit()
}

private func makeZip(_ base: URL, name: String, files: [String: String]) -> URL {
    let dir = base.appendingPathComponent(name + ".d")
    for (path, body) in files {
        let url = dir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
    let out = base.appendingPathComponent(name)
    zip(dir, to: out)
    return out
}

/// 글자 층이 있는 PDF(Core Text로 그림)
private func makeTextPDF(_ url: URL, _ line: String) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
    let attributed = NSAttributedString(string: line, attributes: [.font: font])
    let ctLine = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(ctLine, context)
    context.endPDFPage()
    context.closePDF()
}

/// 글자를 그림으로만 담은 스캔본 같은 PDF
private func makeScannedPDF(_ url: URL, _ lines: [String]) {
    let size = NSSize(width: 1240, height: 1754)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    for (i, line) in lines.enumerated() {
        (line as NSString).draw(at: NSPoint(x: 100, y: 1500 - i * 90),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
    }
    image.unlockFocus()
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    context.beginPDFPage(nil)
    context.draw(cg, in: box)
    context.endPDFPage()
    context.closePDF()
}

private func text(_ url: URL) -> (text: String, author: String?)? {
    DocumentText.extract(path: url.path)
}

private func contains(_ url: URL, _ needle: String, author: String? = nil) -> Bool {
    guard let got = text(url) else { return false }
    let squashed = got.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return squashed.contains(needle) && (author == nil || got.author == author)
}

func docsTest() {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("allspot-docs-\(getpid())")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let core = """
    <?xml version="1.0"?><cp:coreProperties xmlns:cp="c" xmlns:dc="d"><dc:creator>홍길동 &amp; 친구</dc:creator></cp:coreProperties>
    """

    print("오피스 문서")
    let docx = makeZip(base, name: "a.docx", files: [
        "word/document.xml": "<w:document xmlns:w=\"w\"><w:body><w:p><w:r><w:t>수행평가</w:t></w:r><w:r><w:tab/><w:t xml:space=\"preserve\"> 계획 &lt;초안&gt;</w:t></w:r></w:p><w:p><w:r><w:t>둘째 문단</w:t></w:r></w:p></w:body></w:document>",
        "docProps/core.xml": core,
    ])
    check(contains(docx, "수행평가 계획 <초안>", author: "홍길동 & 친구"), "docx 본문·엔티티·작성자")
    check(contains(docx, "둘째 문단"), "docx 문단 나눔")
    let pptx = makeZip(base, name: "b.pptx", files: [
        "ppt/slides/slide2.xml": "<p:sld xmlns:a=\"a\"><a:p><a:r><a:t>두번째 장</a:t></a:r></a:p></p:sld>",
        "ppt/slides/slide10.xml": "<p:sld xmlns:a=\"a\"><a:p><a:r><a:t>열번째 장</a:t></a:r></a:p></p:sld>",
        "ppt/slides/slide1.xml": "<p:sld xmlns:a=\"a\"><a:p><a:r><a:t>첫 장</a:t></a:r></a:p></p:sld>",
        "ppt/notesSlides/notesSlide1.xml": "<p:notes xmlns:a=\"a\"><a:p><a:r><a:t>발표자 메모</a:t></a:r></a:p></p:notes>",
    ])
    let slides = text(pptx)?.text ?? ""
    let order = ["첫 장", "두번째 장", "열번째 장"].compactMap { slides.range(of: $0)?.lowerBound }
    check(order.count == 3 && order == order.sorted(), "pptx 슬라이드 번호 순서(1, 2, 10)")
    check(slides.contains("발표자 메모"), "pptx 발표자 메모")
    let xlsx = makeZip(base, name: "c.xlsx", files: [
        "xl/workbook.xml": "<workbook/>",
        "xl/sharedStrings.xml": "<sst><si><t>공유 문자열</t></si><si><r><t>서식</t></r><r><t>섞인 글</t></r></si></sst>",
        "xl/worksheets/sheet1.xml": "<x:worksheet xmlns:x=\"x\"><x:sheetData><x:row><x:c t=\"str\"><x:v>셀에 바로 쓴 글</x:v></x:c><x:c t=\"inlineStr\"><x:is><x:t>인라인 글</x:t></x:is></x:c></x:row></x:sheetData></x:worksheet>",
    ])
    check(contains(xlsx, "공유 문자열") && contains(xlsx, "서식섞인 글"), "xlsx 공유 문자열")
    check(contains(xlsx, "셀에 바로 쓴 글") && contains(xlsx, "인라인 글"), "xlsx 셀 글(str·inlineStr)")
    let hwpx = makeZip(base, name: "d.hwpx", files: [
        "Contents/section0.xml": "<hs:sec xmlns:hp=\"p\"><hp:p><hp:run><hp:t>한글 문서 본문</hp:t></hp:run></hp:p></hs:sec>",
        "Contents/content.hpf": "<opf:package><opf:meta name=\"creator\" content=\"text\">김교사</opf:meta></opf:package>",
    ])
    check(contains(hwpx, "한글 문서 본문", author: "김교사"), "hwpx 본문·작성자")
    let disguised = base.appendingPathComponent("e.hwp")
    try? FileManager.default.copyItem(at: hwpx, to: disguised)
    check(contains(disguised, "한글 문서 본문"), "이름만 .hwp인 hwpx")

    print("PDF")
    let pdf = base.appendingPathComponent("f.pdf")
    makeTextPDF(pdf, "글자 층이 있는 PDF 본문")
    check(contains(pdf, "글자 층이 있는 PDF 본문"), "PDF 글자 층")
    let scanned = base.appendingPathComponent("g.pdf")
    makeScannedPDF(scanned, ["2026학년도 과학 수행평가 안내", "제출 기한: 11월 20일까지"])
    let started = Date()
    check(contains(scanned, "수행평가 안내") && contains(scanned, "11월 20일"), "스캔본 PDF 글자 인식(OCR)")
    print("    OCR \(Int(Date().timeIntervalSince(started) * 1000))ms")

    print("글자 파일")
    let utf8 = base.appendingPathComponent("h.md")
    try? "# 회의록\n예산 논의".write(to: utf8, atomically: true, encoding: .utf8)
    check(contains(utf8, "예산 논의"), "UTF-8 md")
    let cp949 = base.appendingPathComponent("i.txt")
    let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    try? "옛 한글 인코딩 문서".data(using: korean)?.write(to: cp949)
    check(contains(cp949, "옛 한글 인코딩 문서"), "CP949 txt")
    let utf16 = base.appendingPathComponent("j.txt")
    try? "유니코드 16 문서".data(using: .utf16)?.write(to: utf16)
    check(contains(utf16, "유니코드 16 문서"), "UTF-16 txt(BOM)")
    let binary = base.appendingPathComponent("k.txt")
    try? Data([0x41, 0x00, 0x42, 0x00, 0xFF]).write(to: binary)
    check(text(binary) == nil, "0 바이트가 섞인 이진 파일은 읽지 않음")

    print("망가진 파일")
    let broken = base.appendingPathComponent("l.docx")
    try? Data("PK\u{3}\u{4}garbage".utf8).write(to: broken)
    check(text(broken) == nil, "망가진 zip은 nil(죽지 않음)")
    let truncated = base.appendingPathComponent("m.pptx")
    if let whole = try? Data(contentsOf: pptx) { try? whole.prefix(whole.count / 2).write(to: truncated) }
    check(text(truncated) == nil, "반쯤 잘린 pptx는 nil")
    let fakePDF = base.appendingPathComponent("n.pdf")
    try? Data("%PDF-1.4 nothing".utf8).write(to: fakePDF)
    check(text(fakePDF) == nil, "가짜 PDF는 nil")
    let ole = base.appendingPathComponent("o.hwp")
    try? Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 600)).write(to: ole)
    check(text(ole) == nil, "빈 OLE hwp는 nil")

    print("AI 접근 규칙")
    for name in [".env", ".env.local", "id_rsa", "id_ed25519", "server.pem", "my.key", "credentials.json", "ID_RSA",
                 "auth.json", "oauth_creds.json", ".git-credentials", "AuthKey.p8", "prod.tfvars"] {
        check(AIAccessPolicy.isSecret("/Users/x/p/" + name), "비밀 파일: \(name)")
    }
    check(!AIAccessPolicy.isSecret("/Users/x/p/report.pdf"), "보통 파일은 비밀 아님")
    let policy = AIAccessPolicy(excludedPaths: ["/Users/x/Private/", "~/Work/*/secret"])
    let h = NSHomeDirectory()
    check(!policy.allows(h + "/.ssh/config"), "홈의 숨김 폴더는 고정 규칙으로 막음")
    check(!policy.allows(h + "/.codex/auth.json") && !policy.allows(h + "/.claude.json"), "홈의 숨김 파일도 막음")
    check(policy.allows(h + "/Documents/.hidden/a.pdf"), "홈 바로 아래가 아닌 숨김 폴더는 허용")
    check(!policy.allows("/System/Volumes/Data" + h + "/.ssh/id_rsa"), "/System/Volumes/Data 우회 막음")
    check(!policy.allows("/Users/x/Private"), "끝 / 없이도 같은 폴더로 봄")
    check(!policy.allows("/USERS/X/private/a.txt"), "대소문자 달라도 막음")
    check(policy.allows("/Users/x/Privatex/a.txt"), "이름이 비슷한 옆 폴더는 허용")
    check(!policy.allows(h + "/Work/a/secret/b.txt") && policy.allows(h + "/Work/a/public/b.txt"), "* 규칙")
    check(!policy.allows(h + "/Library/Containers/com.x.app/Data/Library/Cookies/c.binarycookies"), "앱 쿠키 막음")
    check(!policy.allows(h + "/Library/Application Support/Slack/Local Storage/leveldb/1.log"), "앱 저장소 막음")
    check(AIAccessPolicy(excludedPaths: []).allows(h + "/Library/Containers/com.x/Data/Documents/a.pdf"), "앱 컨테이너 문서는 허용")
    check(AIAccessPolicy.isSecret("/a/mcp-auth.json") && AIAccessPolicy.isSecret("/a/aws_credentials"), "비밀 파일 변형")
    for name in ["x.env", "passwords.txt", "secrets.txt", "credentials.md", "Login Data", "firebase-adminsdk-x.json"] {
        check(AIAccessPolicy.isSecret("/a/" + name), "비밀 파일: \(name)")
    }
    check(!policy.allows(h + "/Library/Logs/x.log") && !policy.allows(h + "/Library/LaunchAgents/a.plist"),
          "~/Library는 문서 자리 말고 모두 숨김")
    check(policy.allows(h + "/Library/CloudStorage/GoogleDrive-a/내 드라이브/a.hwp"), "클라우드 드라이브는 보임")
    check(!policy.allows(h + "/Documents/proj/.git/config") && policy.allows(h + "/Documents/proj/.github/a.md"), ".git만 숨김")
    check(!AIAccessPolicy.isSecret("/a/secretary-notes.pdf") && !AIAccessPolicy.isSecret("/a/Secret 계획.hwp"), "문서는 이름에 secret이 있어도 읽음")
    check(policy.allows(h + "/Library/Mobile Documents/com~apple~CloudDocs/a.pdf"), "iCloud 문서는 허용")
    check(AIAccessPolicy(excludedPaths: []).allows(h + "/Documents/a.pdf") && !policy.allows(h + "/Library/Keychains/k"),
          "사용자 목록을 비워도 고정 규칙은 남음")

    print("내용 색인 저장본")
    let store = base.appendingPathComponent("content.bin")
    let backup = store.appendingPathExtension("bak")
    func saveIndex(_ count: Int) -> Bool {
        let index = ContentIndex()
        for i in 0..<count { index.set("/Users/x/d\(i).pdf", size: 1, mtime: 1, text: Array("본문 \(i)".utf8), author: []) }
        return (try? index.save(to: store)) != nil
    }
    func loadCount(_ url: URL) -> Int? {
        let index = ContentIndex()
        return index.load(from: url) ? index.count : nil
    }
    check(saveIndex(1_200) && loadCount(store) == 1_200, "저장·불러오기 1,200개")
    check(saveIndex(1_100) && !FileManager.default.fileExists(atPath: backup.path), "조금 줄면 백업 없음")
    check(saveIndex(100) && loadCount(store) == 100 && loadCount(backup) == 1_100, "절반 넘게 줄면 이전 것을 .bak으로 남김")
    check(saveIndex(10) && loadCount(backup) == 1_100, "작은 저장본끼리는 백업을 덮지 않음")
    let reloaded = ContentIndex()
    check(reloaded.load(from: backup) && reloaded.search(Array("본문 7".utf8)).contains("/Users/x/d7.pdf"), "백업에서 검색됨")

    print("내용 색인 후보 규칙")
    let home = "/Users/x"
    let cases: [(String, Int64, Bool)] = [
        ("\(home)/Documents/a.pdf", 10, true),
        ("\(home)/Documents/big.txt", 2 << 20, false),
        ("\(home)/Developer/app/README.md", 10, false),
        ("\(home)/Documents/node_modules/x/readme.md", 10, false),
        ("\(home)/Documents/proj/node_modules/x/a.pdf", 10, true),
        ("\(home)/.cache/a.pdf", 10, false),
        ("\(home)/Library/Application Support/X/a.pdf", 10, false),
        ("\(home)/Library/CloudStorage/G/내 드라이브/a.hwp", 10, true),
        ("\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/a.docx", 10, true),
        ("\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/a.txt", 10, false),
        ("\(home)/Applications/X.app/Contents/a.pdf", 10, false),
        ("/Library/Documentation/a.pdf", 10, false),
        ("\(home)/Documents/empty.docx", 0, false),
    ]
    for (path, size, expected) in cases {
        check(ContentIndexer.isCandidate(path, size: size) == expected, "\(expected ? "넣음" : "뺌"): \(path.replacingOccurrences(of: home, with: "~"))")
    }

    print(failures == 0 ? "문서·규칙 확인: 모두 통과" : "문서·규칙 확인: \(failures)개 실패")
    exit(failures > 0 ? 1 : 0)
}
