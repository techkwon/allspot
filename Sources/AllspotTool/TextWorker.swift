import AllspotCore
import Darwin
import Foundation

/// 본문 읽기를 짧게 사는 도우미 프로세스(allspot text-worker)에서 한다.
/// MCP 서버는 오래 살아 있으므로, 망가진 문서·압축 폭탄이 서버를 멈추거나 메모리를 붙잡지 않게 시간 제한을 두고 따로 읽는다.
enum TextWorker {
    static let timeout: TimeInterval = 120

    /// 도우미 쪽: 경로 하나를 읽어 표준 출력에 JSON 한 줄로 낸다.
    static func serve(path: String, download: Bool) {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                           download ? IOPOL_MATERIALIZE_DATALESS_FILES_ON : IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        var result: [String: Any] = ["ok": false]
        // 서버가 이미 검사했지만, 이 명령을 직접 불러 규칙을 비켜 가지 못하게 여기서도 같은 검사를 한다.
        guard let checked = try? Engine.checkedPath(path, policy: AIAccessPolicy.fromAppSettings()), checked == path,
              !AIAccessPolicy.isSecret(path) else {
            FileHandle.standardOutput.write(Data(jsonString(["ok": false, "refused": true]).utf8))
            return
        }
        if let extracted = DocumentText.extract(path: path, plainTextLimit: 16 << 20) {
            result = ["ok": true, "text": extracted.text]
            if let author = extracted.author { result["author"] = author }
        }
        FileHandle.standardOutput.write(Data(jsonString(result).utf8))
    }

    /// 서버 쪽: 도우미를 띄워 결과를 받는다. 못 읽었으면 nil, 시간을 넘기면 오류.
    /// executable·timeout은 확인용(allspot self-test)에서만 바꾼다.
    static func run(path: String, download: Bool, executable: URL? = nil,
                    timeout: TimeInterval = TextWorker.timeout) throws -> (text: String, author: String?)? {
        guard let executable = executable ?? Bundle.main.executableURL else { throw ToolError("도우미를 찾지 못했습니다") }
        let process = Process()
        process.executableURL = executable
        // "--" 뒤는 낱말로만 읽으므로 --download를 경로 앞에 둔다.
        process.arguments = ["text-worker"] + (download ? ["--download"] : []) + ["--", path]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ToolError("도우미를 띄우지 못했습니다: \(error)") }

        let timedOut = TimedOut()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning { timedOut.set(); process.terminate() }
        }
        timer.resume()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        try? output.fileHandleForReading.close()

        if timedOut.value { throw ToolError("문서를 읽는 데 \(Int(timeout))초를 넘겨 그만두었습니다: \(path)") }
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("문서를 읽다가 도우미가 멈췄습니다(손상된 파일일 수 있음): \(path)")
        }
        guard object["ok"] as? Bool == true, let text = object["text"] as? String else { return nil }
        return (text, object["author"] as? String)
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }
}

/// 본문 도우미가 멈추거나 엉뚱한 것을 내보낼 때 서버가 버티는지 확인한다(allspot self-test).
enum TextWorkerSelfTest {
    static func run() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("allspot-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func script(_ name: String, _ body: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
            return url
        }
        var ok = true
        func check(_ passed: Bool, _ label: String) {
            print("  \(passed ? "✓" : "✗") \(label)")
            if !passed { ok = false }
        }

        let started = Date()
        do {
            _ = try TextWorker.run(path: "/x", download: false, executable: script("slow", "sleep 30"), timeout: 1)
            check(false, "오래 걸리는 도우미를 끊음")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            check("\(error)".contains("넘겨") && elapsed < 5, "오래 걸리는 도우미를 끊음(\(String(format: "%.1f", elapsed))초)")
        }
        do {
            _ = try TextWorker.run(path: "/x", download: false, executable: script("garbage", "echo not-json"))
            check(false, "엉뚱한 출력은 오류")
        } catch {
            check("\(error)".contains("멈췄"), "엉뚱한 출력은 오류")
        }
        do {
            _ = try TextWorker.run(path: "/x", download: false, executable: script("crash", "kill -9 $$"))
            check(false, "죽은 도우미는 오류")
        } catch {
            check("\(error)".contains("멈췄"), "죽은 도우미는 오류")
        }
        let refused = try? TextWorker.run(path: "/x", download: false,
                                          executable: script("refused", "echo '{\"ok\":false,\"refused\":true}'"))
        check(refused == nil, "거절·못 읽음은 nil")
        let fine = try? TextWorker.run(path: "/x", download: false,
                                       executable: script("fine", "echo '{\"ok\":true,\"text\":\"안녕\",\"author\":\"홍\"}'"))
        check(fine?.text == "안녕" && fine?.author == "홍", "정상 출력은 본문·작성자")
        return ok
    }
}
