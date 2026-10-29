import Darwin
import Foundation

/// 디렉터리를 여러 스레드로 동시에 읽어 색인에 넣는다.
/// getattrlistbulk는 이름·종류·크기·수정 시각을 한 번의 시스템 호출로 수십~수백 개씩 돌려주어
/// readdir + stat 조합보다 훨씬 빠르다. Windows Everything이 MFT를 직접 읽는 것에 해당하는 부분이다.
final class Scanner {
    let index: FileIndex
    let excluded: [String]
    let threadCount: Int
    var isCancelled: () -> Bool = { false }
    var onProgress: (() -> Void)?

    private let condition = NSCondition()
    private var pending: [(Int32, String)] = []
    private var active = 0

    init(index: FileIndex, excluded: [String], threadCount: Int = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount))) {
        self.index = index
        self.excluded = excluded
        self.threadCount = threadCount
    }

    static func isExcluded(_ path: String, _ excluded: [String]) -> Bool {
        for e in excluded where path == e || path.hasPrefix(e.hasSuffix("/") ? e : e + "/") { return true }
        return false
    }

    /// 주어진 디렉터리들의 아래를 모두 읽는다. 끝날 때까지 돌아오지 않는다.
    func scan(_ starts: [(Int32, String)]) {
        guard !starts.isEmpty else { return }
        Self.disableDatalessMaterialization()
        condition.lock()
        pending = starts
        active = 0
        condition.unlock()
        DispatchQueue.concurrentPerform(iterations: threadCount) { _ in worker() }
    }

    private func worker() {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var batch = EntryBatch()
        var lastProgress = Date()
        while true {
            condition.lock()
            while pending.isEmpty && active > 0 { condition.wait() }
            if pending.isEmpty || isCancelled() {
                pending.removeAll()
                condition.broadcast()
                condition.unlock()
                return
            }
            let (dir, path) = pending.removeLast()
            active += 1
            condition.unlock()

            batch.removeAll()
            _ = Self.list(path, into: &batch, buffer: buffer, bufferSize: bufferSize)
            var subdirectories: [(Int32, String)] = []
            if batch.count > 0 {
                let first = index.lock.write { index.isLive(Int(dir)) ? index.appendLocked(batch, to: dir) : -1 }
                if first >= 0 {
                    for i in 0..<batch.count where batch.flags[i] & EntryFlag.directory != 0 && batch.flags[i] & EntryFlag.symlink == 0 {
                        let name = batch.name(i)
                        let childPath = path == "/" ? "/" + name : path + "/" + name
                        if !Self.isExcluded(childPath, excluded) {
                            subdirectories.append((first + Int32(i), childPath))
                        }
                    }
                }
            }

            condition.lock()
            pending.append(contentsOf: subdirectories)
            active -= 1
            condition.broadcast()
            condition.unlock()

            if let onProgress, Date().timeIntervalSince(lastProgress) > 0.5 {
                lastProgress = Date()
                onProgress()
            }
        }
    }

    /// iCloud Drive 등에서 "필요할 때 내려받기"로 비워 둔 폴더를 읽다가 내려받기가 시작되지 않게 한다.
    static func disableDatalessMaterialization() {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3, IOPOL_SCOPE_PROCESS = 0, IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1
        _ = setiopolicy_np(3, 0, 1)
    }

    /// 디렉터리 하나의 항목을 읽는다. 실패하면 errno를 돌려준다(성공은 0).
    @discardableResult
    static func list(_ path: String, into batch: inout EntryBatch, buffer: UnsafeMutableRawPointer, bufferSize: Int) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        request.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

        let errorBit = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
        let nameBit = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
        let typeBit = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        let modBit = attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        let lengthBit = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & errorBit != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 { continue }
                }
                guard returned.commonattr & nameBit != 0 else { continue }
                let nameReference = field.loadUnaligned(as: attrreference_t.self)
                let namePointer = (field + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
                let nameLength = max(0, Int(nameReference.attr_length) - 1) // 끝의 NUL 제외
                field += MemoryLayout<attrreference_t>.size

                var objectType: UInt32 = 0
                if returned.commonattr & typeBit != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified: Int64 = 0
                if returned.commonattr & modBit != 0 {
                    modified = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var size: Int64 = 0
                if returned.fileattr & lengthBit != 0 {
                    size = field.loadUnaligned(as: Int64.self)
                    field += 8
                }

                var entryFlags: UInt8 = 0
                if objectType == VDIR.rawValue { entryFlags |= EntryFlag.directory }
                if objectType == VLNK.rawValue { entryFlags |= EntryFlag.symlink }
                batch.append(name: UnsafeBufferPointer(start: namePointer, count: nameLength), flags: entryFlags,
                             size: entryFlags & EntryFlag.directory != 0 ? 0 : size, mtime: modified)
            }
        }
    }
}
