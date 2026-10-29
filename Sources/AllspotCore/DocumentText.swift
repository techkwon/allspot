import Compression
import Darwin
import Foundation
import PDFKit
import Vision

/// 문서 파일에서 본문 글자와 작성자를 꺼낸다(내용 색인과 AI용 도구가 함께 쓴다).
/// 확장자보다 파일 앞부분(zip·PDF·OLE 표시)을 먼저 보고 읽는 법을 고른다.
public enum DocumentText {
    /// 내용 색인에 넣는 확장자
    public static let indexedExtensions: Set<String> = ["hwp", "hwpx", "pdf", "docx", "pptx", "xlsx", "txt", "md"]
    /// 그냥 글자로 된 파일
    public static let plainExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yaml", "yml"]
    /// PDF에서 읽는 쪽 수 상한(스캔본 수천 쪽 같은 것에 오래 매달리지 않게)
    static let pdfPageLimit = 2_000
    /// 본문 상한(바이트). 넘으면 뒤는 버린다.
    static let textLimit = 8 << 20

    /// 경로의 문서를 읽는다. 읽을 수 없거나 지원하지 않는 형식이면 nil.
    /// plainTextLimit: 글자 파일은 앞에서 이만큼만 읽는다.
    public static func extract(path: String, plainTextLimit: Int = 1 << 20) -> (text: String, author: String?)? {
        let ext = (path as NSString).pathExtension.lowercased()
        let head = Self.head(path, 8)
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            guard let zip = ZipArchive(path: path) else { return nil }
            return office(zip) ?? HwpxText.extract(zip)
        }
        if head.starts(with: Array("%PDF".utf8)) { return pdf(path) }
        if ext == "hwp" {
            guard let data = readAll(path, limit: 300 << 20) else { return nil }
            return HwpText.extract(data)
        }
        if plainExtensions.contains(ext) { return plain(path, limit: plainTextLimit) }
        return nil
    }

    // MARK: - 오피스(docx·pptx·xlsx)

    /// zip 안의 이름을 보고 워드·파워포인트·엑셀을 가른다. 아니면 nil.
    static func office(_ zip: ZipArchive) -> (text: String, author: String?)? {
        let names = zip.names
        var units: [UInt8] = []
        if names.contains("word/document.xml") {
            for name in ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"] {
                if let xml = zip.read(name) { XMLText.append(xml, to: &units) }
                if units.count > textLimit { break }
            }
        } else if names.contains(where: { $0.hasPrefix("ppt/slides/slide") }) {
            for name in numbered(names, prefix: "ppt/slides/slide") + numbered(names, prefix: "ppt/notesSlides/notesSlide") {
                if let xml = zip.read(name) { XMLText.append(xml, to: &units) }
                if units.count > textLimit { break }
            }
        } else if names.contains("xl/workbook.xml") {
            // 셀 글자는 대부분 공유 문자열 표에 모여 있다(숫자는 넣지 않는다).
            if let xml = zip.read("xl/sharedStrings.xml") { XMLText.append(xml, to: &units, paragraph: "si") }
            // 공유 표를 쓰지 않고 셀에 바로 적은 글자(inlineStr의 <t>, str의 <v>)도 있다. <v>에는 숫자도 들어간다.
            for name in numbered(names, prefix: "xl/worksheets/sheet") {
                if let xml = zip.read(name) { XMLText.append(xml, to: &units, paragraph: "row", text: ["t", "v"]) }
                if units.count > textLimit { break }
            }
        } else {
            return nil
        }
        if units.count > textLimit { units.removeSubrange(textLimit...) }
        var author: String?
        if let core = zip.read("docProps/core.xml") {
            author = XMLText.firstValue(core, element: "creator")
        }
        return (String(decoding: units, as: UTF8.self), author)
    }

    /// prefix1.xml, prefix2.xml … 을 번호 순서대로
    static func numbered(_ names: [String], prefix: String) -> [String] {
        names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".xml") else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(4)).map { ($0, name) }
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    // MARK: - PDF

    /// 큰 PDF는 읽는 동안 수백 MB를 쓰므로 한 번에 하나만 읽는다(도우미 프로세스끼리도 파일 잠금으로 줄을 세운다).
    private static let bigPDFGate = DispatchSemaphore(value: 1)
    private static let bigPDFLockPath = NSTemporaryDirectory() + "allspot-big-pdf.lock"

    static func pdf(_ path: String) -> (text: String, author: String?)? {
        var st = stat()
        let big = stat(path, &st) == 0 && st.st_size > 16 << 20
        var lockFd: Int32 = -1
        if big {
            bigPDFGate.wait()
            lockFd = open(bigPDFLockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if lockFd >= 0 { flock(lockFd, LOCK_EX) }
        }
        defer {
            if big {
                if lockFd >= 0 { flock(lockFd, LOCK_UN); close(lockFd) }
                bigPDFGate.signal()
            }
        }
        return autoreleasepool {
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked else { return nil }
            var text = ""
            var bytes = 0
            for i in 0..<min(document.pageCount, pdfPageLimit) {
                // 쪽마다 풀어 줘야 쪽 개체·글꼴 캐시가 쌓이지 않는다.
                let page: String? = autoreleasepool {
                    // 그림 자리에 끼는 개체 대치 문자(U+FFFC)는 뺀다.
                    document.page(at: i)?.string?.replacingOccurrences(of: "\u{FFFC}", with: "")
                }
                guard let page else { continue }
                text += page
                text += "\n"
                bytes += page.utf8.count
                if bytes > textLimit { break }
            }
            // 글자 층이 거의 없으면 스캔본으로 보고 앞쪽 몇 쪽을 글자 인식(OCR)한다.
            if document.pageCount > 0 && text.unicodeScalars.filter({ !CharacterSet.whitespacesAndNewlines.contains($0) }).count < 100 {
                let recognized = ocr(document)
                if !recognized.isEmpty { text = recognized }
            }
            let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
            return (text, author)
        }
    }

    /// 스캔본에서 글자 인식할 쪽 수 상한(한 쪽에 0.3~1초 걸린다)
    static let ocrPageLimit = 20

    /// PDF 쪽을 회색조 그림으로 그려 Vision으로 글자를 읽는다(한국어·영어).
    static func ocr(_ document: PDFDocument) -> String {
        var lines: [String] = []
        for i in 0..<min(document.pageCount, ocrPageLimit) {
            autoreleasepool {
                guard let page = document.page(at: i)?.pageRef else { return }
                let box = page.getBoxRect(.mediaBox)
                guard box.width > 1, box.height > 1 else { return }
                // 긴 변이 2000픽셀 안팎이 되게(작은 글자도 읽히고 메모리는 적당하게)
                let scale = min(3.0, 2000 / max(box.width, box.height))
                let width = Int(box.width * scale), height = Int(box.height * scale)
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY)
                context.drawPDFPage(page)
                guard let image = context.makeImage() else { return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ko-KR", "en-US"]
                request.usesLanguageCorrection = true
                guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return }
                for observation in request.results ?? [] {
                    if let line = observation.topCandidates(1).first?.string { lines.append(line) }
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 글자 파일

    /// UTF-8을 먼저 보고, 아니면 UTF-16(BOM)·CP949(EUC-KR) 순서로 읽는다. 0 바이트가 섞인 이진 파일은 nil.
    static func plain(_ path: String, limit: Int) -> (text: String, author: String?)? {
        guard var bytes = readPrefix(path, limit: limit) else { return nil }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            if bytes.count % 2 == 1 { bytes.removeLast() }
            return String(bytes: bytes, encoding: .utf16).map { ($0, nil) }
        }
        if bytes.prefix(8192).contains(0) { return nil }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        // 중간에서 끊겼으면 끝의 덜 끝난 UTF-8 글자를 떼어 낸다.
        var cut = bytes.count
        var back = 0
        while cut > 0 && back < 4 && bytes[cut - 1] & 0xC0 == 0x80 { cut -= 1; back += 1 }
        if cut > 0 && bytes[cut - 1] >= 0xC0 {
            let lead = bytes[cut - 1]
            let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
            cut = back + 1 < need ? cut - 1 : bytes.count
        } else {
            cut = bytes.count
        }
        if let text = String(bytes: bytes[..<cut], encoding: .utf8) { return (text, nil) }
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        if let text = String(bytes: bytes, encoding: cp949) { return (text, nil) }
        return (String(decoding: bytes, as: UTF8.self), nil)
    }

    // MARK: - 파일 읽기

    static func head(_ path: String, _ count: Int) -> [UInt8] {
        readPrefix(path, limit: count) ?? []
    }

    static func readPrefix(_ path: String, limit: Int) -> [UInt8]? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        let count = min(Int(st.st_size), limit)
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(done)) }
            if n <= 0 { break }
            done += n
        }
        if done < count { out.removeSubrange(done...) }
        return out
    }

    /// limit보다 크면 nil
    static func readAll(_ path: String, limit: Int) -> Data? {
        var st = stat()
        guard stat(path, &st) == 0, Int(st.st_size) <= limit, let bytes = readPrefix(path, limit: limit) else { return nil }
        return Data(bytes)
    }
}

/// XML에서 글자 요소(<*:t>) 안의 글자만 모은다. 접두어(hp:, w:, a:)는 가리지 않는다.
enum XMLText {
    /// paragraph 요소가 끝나면 줄을 바꾸고, tab·br·lineBreak는 빈칸으로 바꾼다. text: 글자를 모을 요소 이름들
    static func append(_ xml: [UInt8], to out: inout [UInt8], paragraph: String = "p", text: [String] = ["t"]) {
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), amp = UInt8(ascii: "&")
        let paragraphName = Array(paragraph.utf8)
        let textNames = text.map { Array($0.utf8) }
        var inText = 0
        var i = 0
        let n = xml.count
        while i < n {
            let c = xml[i]
            if c == lt {
                var j = i + 1
                let closing = j < n && xml[j] == slash
                if closing { j += 1 }
                let nameStart = j
                while j < n && xml[j] != gt && xml[j] != slash && xml[j] != 0x20 && xml[j] != 0x09 && xml[j] != 0x0A && xml[j] != 0x0D { j += 1 }
                var localStart = nameStart
                for k in nameStart..<j where xml[k] == UInt8(ascii: ":") { localStart = k + 1 }
                let local = xml[localStart..<j]
                var end = j
                while end < n && xml[end] != gt { end += 1 }
                let selfClosing = end > 0 && end < n && xml[end - 1] == slash
                if textNames.contains(where: { local.elementsEqual($0) }) {
                    if closing {
                        inText = max(0, inText - 1)
                        if text.count > 1 { out.append(0x20) }
                    } else if !selfClosing {
                        inText += 1
                    }
                } else if closing && local.elementsEqual(paragraphName) {
                    out.append(0x0A)
                } else if local.elementsEqual("tab".utf8) || local.elementsEqual("br".utf8) || local.elementsEqual("lineBreak".utf8) {
                    out.append(0x20)
                }
                i = end + 1
            } else if inText > 0 {
                if c == amp, let (bytes, length) = entity(xml, i) {
                    out.append(contentsOf: bytes)
                    i += length
                } else {
                    out.append(c)
                    i += 1
                }
            } else {
                i += 1
            }
        }
    }

    /// &amp; &lt; &#44032; 같은 XML 문자 참조를 풀어 UTF-8 바이트와 차지한 길이를 돌려준다.
    static func entity(_ xml: [UInt8], _ start: Int) -> ([UInt8], Int)? {
        var end = start + 1
        while end < xml.count && end - start < 12 && xml[end] != UInt8(ascii: ";") { end += 1 }
        guard end < xml.count, xml[end] == UInt8(ascii: ";") else { return nil }
        let name = String(decoding: xml[(start + 1)..<end], as: UTF8.self)
        let length = end - start + 1
        switch name {
        case "amp": return ([UInt8(ascii: "&")], length)
        case "lt": return ([UInt8(ascii: "<")], length)
        case "gt": return ([UInt8(ascii: ">")], length)
        case "quot": return ([UInt8(ascii: "\"")], length)
        case "apos": return ([UInt8(ascii: "'")], length)
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (Array(String(Character(scalar)).utf8), length)
        }
    }

    /// 처음 나오는 <*:element>값</*:element>의 값(엔티티를 푼 것)
    static func firstValue(_ xml: [UInt8], element: String) -> String? {
        let text = String(decoding: xml, as: UTF8.self)
        guard let open = text.range(of: ":\(element)>") ?? text.range(of: "<\(element)>") else { return nil }
        let rest = text[open.upperBound...]
        guard let close = rest.firstIndex(of: "<") else { return nil }
        var out: [UInt8] = []
        let raw = Array(rest[..<close].utf8)
        var i = 0
        while i < raw.count {
            if raw[i] == UInt8(ascii: "&"), let (bytes, length) = entity(raw, i) {
                out.append(contentsOf: bytes)
                i += length
            } else {
                out.append(raw[i])
                i += 1
            }
        }
        let value = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// 꼭 필요한 만큼만 읽는 zip 읽기(저장·deflate 압축만, zip64는 지원하지 않음).
/// 파일에서 열면 목록과 필요한 항목만 그때그때 읽으므로, 그림이 많은 수 GB짜리 pptx도 가볍게 다룬다.
final class ZipArchive {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    /// (위치, 길이) → 바이트
    private let fetch: (Int, Int) -> [UInt8]?
    private let closer: (() -> Void)?
    private let entries: [String: Entry]
    var names: [String] { Array(entries.keys) }

    private init(fetch: @escaping (Int, Int) -> [UInt8]?, closer: (() -> Void)?, entries: [String: Entry]) {
        self.fetch = fetch
        self.closer = closer
        self.entries = entries
    }

    deinit { closer?() }

    convenience init?(_ source: Data) {
        let data = source
        let fetch: (Int, Int) -> [UInt8]? = { offset, count in
            guard offset >= 0, count >= 0, offset <= data.count - count else { return nil }
            return [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
        }
        guard let entries = Self.directory(length: data.count, fetch: fetch) else { return nil }
        self.init(fetch: fetch, closer: nil, entries: entries)
    }

    convenience init?(path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); return nil }
        let length = Int(st.st_size)
        let fetch: (Int, Int) -> [UInt8]? = { offset, count in
            guard offset >= 0, count >= 0, offset <= length - count else { return nil }
            var out = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                let n = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset + done)) }
                if n <= 0 { return nil }
                done += n
            }
            return out
        }
        guard let entries = Self.directory(length: length, fetch: fetch) else { close(fd); return nil }
        self.init(fetch: fetch, closer: { close(fd) }, entries: entries)
    }

    @inline(__always) private static func u16(_ d: [UInt8], _ i: Int) -> UInt16 { UInt16(d[i]) | UInt16(d[i + 1]) << 8 }
    @inline(__always) private static func u32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    /// 끝에서 중앙 디렉터리 끝 표시(PK\5\6)를 찾아 항목 목록을 읽는다.
    private static func directory(length n: Int, fetch: (Int, Int) -> [UInt8]?) -> [String: Entry]? {
        guard n >= 22 else { return nil }
        let tailLength = min(n, 22 + 65_535)
        guard let tail = fetch(n - tailLength, tailLength) else { return nil }
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = Int(u16(tail, eocd + 10))
        let directorySize = Int(u32(tail, eocd + 12))
        let directoryOffset = Int(u32(tail, eocd + 16))
        guard directorySize <= 64 << 20, let d = fetch(directoryOffset, directorySize) else { return nil }
        var entries: [String: Entry] = [:]
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x0201_4B50 else { return nil }
            let nameLength = Int(u16(d, p + 28))
            guard p + 46 + nameLength <= d.count else { return nil }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: u16(d, p + 10), compressedSize: Int(u32(d, p + 20)), size: Int(u32(d, p + 24)),
                                  localOffset: Int(u32(d, p + 42)))
            p += 46 + nameLength + Int(u16(d, p + 30)) + Int(u16(d, p + 32))
        }
        return entries
    }

    func read(_ name: String) -> [UInt8]? {
        guard let e = entries[name], e.size < 256 << 20, e.compressedSize < 256 << 20,
              let local = fetch(e.localOffset, 30), Self.u32(local, 0) == 0x0403_4B50 else { return nil }
        let start = e.localOffset + 30 + Int(Self.u16(local, 26)) + Int(Self.u16(local, 28))
        guard let packed = fetch(start, e.compressedSize) else { return nil }
        switch e.method {
        case 0:
            return packed
        case 8:
            guard e.size > 0, !packed.isEmpty else { return [] }
            var out = [UInt8](repeating: 0, count: e.size)
            // COMPRESSION_ZLIB는 머리말 없는 deflate(zip과 같은 형식)를 푼다.
            let written = packed.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, e.size, src.baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
                }
            }
            return written == e.size ? out : nil
        default:
            return nil
        }
    }
}
