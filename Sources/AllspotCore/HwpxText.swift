import Compression
import Foundation

/// 한글 hwpx 문서(zip 안의 XML)에서 본문 글자와 작성자를 꺼낸다.
enum HwpxText {
    static func extract(_ data: Data) -> (text: String, author: String?)? {
        guard let zip = ZipArchive(data) else { return nil }
        return extract(zip)
    }

    static func extract(_ zip: ZipArchive) -> (text: String, author: String?)? {
        // Contents/section0.xml, section1.xml … 을 번호 순서대로 읽는다.
        let sections = zip.names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("Contents/section"), name.hasSuffix(".xml") else { return nil }
                let number = name.dropFirst("Contents/section".count).dropLast(".xml".count)
                return Int(number).map { ($0, name) }
            }
            .sorted { $0.0 < $1.0 }
        var units: [UInt8] = []
        for (_, name) in sections {
            if let xml = zip.read(name) { XMLText.append(xml, to: &units) }
            if units.count > DocumentText.textLimit { break }   // 압축 폭탄·거대 문서에서 멈춘다
        }
        if units.count > DocumentText.textLimit { units.removeSubrange(DocumentText.textLimit...) }
        if units.isEmpty, let preview = zip.read("Preview/PrvText.txt") {
            units = preview
        }
        guard !units.isEmpty else { return nil }
        let text = String(decoding: units, as: UTF8.self)
        var author: String?
        if let hpf = zip.read("Contents/content.hpf") {
            author = metaValue(String(decoding: hpf, as: UTF8.self), name: "creator")
        }
        return (text, author)
    }

    /// content.hpf의 <opf:meta name="creator" …>값</opf:meta>
    static func metaValue(_ hpf: String, name: String) -> String? {
        guard let range = hpf.range(of: "name=\"\(name)\"") else { return nil }
        guard let open = hpf[range.upperBound...].firstIndex(of: ">") else { return nil }
        let rest = hpf[hpf.index(after: open)...]
        guard let close = rest.firstIndex(of: "<") else { return nil }
        let value = rest[..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

