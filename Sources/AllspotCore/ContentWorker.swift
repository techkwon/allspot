import Darwin
import Foundation

/// 문서 본문 읽기를 따로 띄운 도우미 프로세스(allspot index-worker)에 맡긴다.
///
/// PDFKit 등은 큰 문서를 읽는 동안 수백 MB를 쓰는데, macOS의 메모리 할당기는 한 번 커진 몫을 프로세스가
/// 끝날 때까지 돌려주지 않는다. 짧게 살다 끝나는 도우미에서 읽으면 앱은 본문 키만 받아 가벼움을 유지하고,
/// 망가진 문서 때문에 읽기가 죽거나 멈춰도 앱은 멀쩡하다.
///
/// 주고받는 형식: 앱 → 도우미 표준 입력에 경로들(NUL로 구분, 끝까지 쓰고 닫음).
/// 도우미 → 앱 표준 출력에 경로 순서대로 [u8 읽음 여부][u32 본문 키 길이][본문 키][u32 작성자 키 길이][작성자 키].
public enum ContentWorker {
    static let maxBody = 64 << 20
    static let maxAuthor = 1 << 20

    // MARK: - 도우미 쪽

    /// 도우미 프로세스의 본체. 경로를 하나씩 차례로 읽어 결과를 바로 내보낸다.
    public static func serve(includeCloud: Bool) {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                           includeCloud ? IOPOL_MATERIALIZE_DATALESS_FILES_ON : IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        signal(SIGPIPE, SIG_IGN)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        for raw in input.split(separator: 0, omittingEmptySubsequences: true) {
            let path = String(decoding: raw, as: UTF8.self)
            let ok: Bool = autoreleasepool {
                // 앱은 내용 색인 후보만 보낸다. 직접 불러 숨김 폴더·앱 내부 파일을 읽히지 못하게 같은 규칙을 다시 본다.
                var st = stat()
                let candidate = stat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG &&
                    ContentIndexer.isCandidate(path, size: Int64(st.st_size))
                let keys = candidate ? ContentIndexer.extractKeys(path: path) : nil
                var record: [UInt8] = [keys == nil ? 0 : 1]
                let body = keys.map { Array($0.body.prefix(maxBody)) } ?? []
                let author = keys.map { Array($0.author.prefix(maxAuthor)) } ?? []
                append(UInt32(body.count), to: &record)
                record += body
                append(UInt32(author.count), to: &record)
                record += author
                return writeAll(STDOUT_FILENO, record)
            }
            if !ok { return } // 앱이 그만 듣는다
        }
    }

    private static func append(_ value: UInt32, to out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out += $0 }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    // MARK: - 앱 쪽

    /// 도우미 하나를 띄워 paths를 읽힌다. 받은 결과마다 deliver(순번, 키)를 부르고, 받은 개수를 돌려준다.
    /// 받은 개수가 paths보다 적으면 그 다음 경로에서 도우미가 죽었거나 너무 오래 걸려 끊은 것이다.
    public static func run(worker: URL, paths: [String], includeCloud: Bool, stallTimeout: TimeInterval = 120,
                    deliver: (Int, (body: [UInt8], author: [UInt8])?) -> Void) -> Int {
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = worker
        process.arguments = ["index-worker"] + (includeCloud ? ["--include-cloud"] : [])
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return 0 }

        var payload: [UInt8] = []
        for path in paths { payload += path.utf8; payload.append(0) }
        // fd는 FileHandle이 갖고 있으므로 닫기도 FileHandle로 한다(직접 close하면 나중에 같은 번호를 두 번 닫게 된다).
        _ = writeAll(input.fileHandleForWriting.fileDescriptor, payload)
        try? input.fileHandleForWriting.close()

        // 한 문서에 너무 오래 매달리면(망가진 PDF 등) 도우미를 끝낸다.
        let progressLock = NSLock()
        var lastProgress = Date()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler {
            progressLock.lock()
            let stalled = Date().timeIntervalSince(lastProgress) > stallTimeout
            progressLock.unlock()
            if stalled && process.isRunning { process.terminate() }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        let fd = output.fileHandleForReading.fileDescriptor
        func readExact(_ count: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                let n = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + done, count - done) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return nil }
                done += n
            }
            return out
        }
        func readLength(_ limit: Int) -> Int? {
            guard let raw = readExact(4) else { return nil }
            let value = Int(UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24)
            return value <= limit ? value : nil
        }

        var delivered = 0
        while delivered < paths.count {
            guard let flag = readExact(1), let bodyLength = readLength(maxBody), let body = readExact(bodyLength),
                  let authorLength = readLength(maxAuthor), let author = readExact(authorLength) else { break }
            deliver(delivered, flag[0] == 1 ? (body, author) : nil)
            delivered += 1
            progressLock.lock()
            lastProgress = Date()
            progressLock.unlock()
        }
        if process.isRunning && delivered < paths.count { process.terminate() }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        return delivered
    }
}
