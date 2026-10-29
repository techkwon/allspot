import Darwin
import Foundation

/// AI 도구(CLI·MCP)에 보여 주지 않을 곳을 정한다.
/// 빼는 위치 안의 항목과 비밀 정보가 들었을 만한 파일은 검색 결과에서 숨기고(개수에도 넣지 않는다) 읽어 주지 않는다.
///
/// 경로 규칙은 대소문자를 가리지 않고(APFS 기본), `*`를 쓸 수 있다(`*`는 / 도 건너뛴다).
/// 규칙에 맞는 위치와 그 안의 모든 항목이 빠진다.
public struct AIAccessPolicy: Sendable {
    public static let excludedPathsKey = "aiExcludedPaths"

    /// 사용자가 끌 수 없는 규칙: 비밀번호·토큰·쿠키·저장소 설정이 모이는 곳.
    /// ~/Library는 따로, 사용자 문서가 있는 곳(iCloud Drive, 클라우드 드라이브, 앱 컨테이너의 Documents)만 보인다.
    public static let builtInExcludedPaths = [
        "~/.*",                                             // 홈의 숨김 폴더·파일(.ssh .aws .config .codex .claude.json …)
        "*/.git",                                           // 저장소 설정(원격 주소에 토큰이 들어가기도 한다)
        "/Library/Keychains", "/private/var/db", "/private/var/root",
    ]

    /// ~/Library 안에서 AI에게 보이는 곳
    static let visibleLibraryPaths = ["~/Library/Mobile Documents", "~/Library/CloudStorage", "~/Library/Containers/*/Data/Documents"]

    /// 설정에서 고칠 수 있는 기본 목록(개인 대화·메일)
    public static let defaultExcludedPaths = [
        "~/Library/Messages", "~/Library/Mail", "~/Library/Containers/com.kakao.KakaoTalkMac",
    ]

    /// 내용을 읽어 주지 않는 파일 이름(소문자로 비교)
    static let secretNames: Set<String> = [
        ".env", ".netrc", ".npmrc", ".pypirc", ".pgpass", ".git-credentials", "credentials", "credentials.json",
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "secrets.json", "secrets.yaml", "secrets.yml",
        "service-account.json", "keychain", "auth.json", "oauth_creds.json", "token.json", "tokens.json",
        "hosts.yml", "config.json.bak", "settings.local.json",
    ]
    static let secretWords = ["credential", "secret", "password", "passwd", "login data", "web data", "adminsdk",
                              "service-account", "service_account", "serviceaccount", "private_key", "privatekey"]
    static let documentExtensions: Set<String> = ["hwp", "hwpx", "pdf", "docx", "pptx", "xlsx", "doc", "ppt", "xls", "pages"]
    static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "env", "pfx", "p8", "ppk", "keychain", "keychain-db", "kdbx", "ovpn", "jks", "keystore", "tfvars",
    ]

    /// 사용자 목록(설정에 보이는 것). 실제 판정에는 고정 규칙이 함께 쓰인다.
    public let excludedPaths: [String]
    private let rules: [Rule]
    private let library: String
    private let libraryRules: [Rule]

    /// prefix: 첫 `*` 앞까지(소문자). pattern이 있으면 prefix가 맞은 뒤 fnmatch로 한 번 더 본다.
    private struct Rule: Sendable {
        let prefix: String
        let pattern: String?
    }

    public init(excludedPaths: [String]) {
        self.excludedPaths = excludedPaths.compactMap(Self.normalize)
        rules = (Self.builtInExcludedPaths.compactMap(Self.normalize) + self.excludedPaths).map(Self.rule)
        library = (NSHomeDirectory() + "/Library").lowercased()
        libraryRules = Self.visibleLibraryPaths.compactMap(Self.normalize).map(Self.rule)
    }

    private static func rule(_ entry: String) -> Rule {
        let lower = entry.lowercased()
        guard let star = lower.firstIndex(of: "*") else { return Rule(prefix: lower, pattern: nil) }
        return Rule(prefix: String(lower[..<star]), pattern: lower)
    }

    /// path(소문자)가 규칙의 위치이거나 그 안인지
    private static func matches(_ rule: Rule, _ lower: String) -> Bool {
        guard lower.hasPrefix(rule.prefix) else { return false }
        guard let pattern = rule.pattern else {
            return lower.count == rule.prefix.count || lower.dropFirst(rule.prefix.count).first == "/"
        }
        return fnmatch(pattern, lower, 0) == 0 || fnmatch(pattern + "/*", lower, 0) == 0
    }

    /// ~를 풀고, 끝의 /를 떼고, 같은 곳을 가리키는 다른 이름(/System/Volumes/Data, 심볼릭 링크)을 하나로 맞춘다.
    static func normalize(_ raw: String) -> String? {
        var p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("~") { p = NSHomeDirectory() + p.dropFirst() }
        guard p.hasPrefix("/") || p.hasPrefix("*") else { return nil }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if !p.contains("*"), let resolved = realpath(p, nil) {
            p = String(cString: resolved)
            free(resolved)
        }
        return stripDataVolume(p)
    }

    /// /System/Volumes/Data/Users/… → /Users/…
    public static func stripDataVolume(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        guard path.count > data.count, path.lowercased().hasPrefix(data.lowercased() + "/") else { return path }
        return String(path.dropFirst(data.count))
    }

    /// 앱 설정(UserDefaults)에 저장된 목록, 없으면 기본 목록
    public static func fromAppSettings() -> AIAccessPolicy {
        let defaults = UserDefaults(suiteName: "com.techkwon.allspot")
        return AIAccessPolicy(excludedPaths: defaults?.stringArray(forKey: excludedPathsKey) ?? defaultExcludedPaths)
    }

    /// 경로를 AI에게 보여도 되는지(빼는 위치 안이 아닌지). path는 정규화된 절대 경로여야 한다.
    public func allows(_ path: String) -> Bool {
        let lower = Self.stripDataVolume(path).lowercased()
        if lower.hasPrefix(library + "/") && !libraryRules.contains(where: { Self.matches($0, lower) }) { return false }
        return !rules.contains { Self.matches($0, lower) }
    }

    /// 비밀 정보가 들었을 만한 파일인지(.env, id_rsa, *.pem 같은 것)
    public static func isSecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if secretNames.contains(name) || name.hasPrefix(".env.") || name.hasPrefix("id_rsa") { return true }
        let ext = (name as NSString).pathExtension
        if secretExtensions.contains(ext) { return true }
        // mcp-auth.json, oauth-token.json, aws_credentials, passwords.txt 같은 변형.
        // 사람이 쓰는 문서(한글·워드·PDF 등)는 이름만 보고 막지 않는다. 글자 파일(txt·md)은 막는다.
        if documentExtensions.contains(ext) { return false }
        if name.hasSuffix("auth.json") || name.hasSuffix("token.json") || name.hasSuffix("tokens.json") { return true }
        return secretWords.contains { name.contains($0) }
    }
}
