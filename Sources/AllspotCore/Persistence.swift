import Foundation

/// 색인을 디스크에 통째로 저장하고 읽는다. 다음 실행 때 다시 훑지 않고 바로 검색할 수 있게 하고,
/// 저장 시점의 FSEvents 번호부터 놓친 변경만 다시 받는다(Windows Everything의 USN 저널 재생과 같은 역할).
///
/// 형식 3은 배열마다 16KB 경계에 맞춰 저장해서, 읽을 때 메모리로 복사하지 않고 파일을 그대로 비춰 쓴다.
/// 그러면 바뀌지 않은 부분은 macOS가 필요할 때 디스크에서 다시 읽는 메모리로 잡혀 앱 몫으로 거의 세지 않는다.
extension FileIndex {
    static let magic: UInt32 = 0x414C_5350 // "ALSP"
    static let formatVersion: UInt32 = 3
    /// 형식 2(배열을 빈틈없이 이어 붙인 예전 형식)도 읽는다. 읽은 뒤 저장하면 형식 3이 된다.
    static let legacyFormatVersion: UInt32 = 2

    struct Header {
        var magic: UInt32
        var version: UInt32
        var eventId: UInt64
        var configHash: UInt64
        var count: UInt64
        var nameBytes: UInt64
        var orderCount: UInt64
    }

    /// 비춰 쓰는 배열 묶음
    private struct Sections {
        let parent: RawArray<Int32>
        let nameStart: RawArray<UInt32>
        let nameLen: RawArray<UInt16>
        let keyStart: RawArray<UInt32>
        let keyLen: RawArray<UInt16>
        let size: RawArray<Int64>
        let mtime: RawArray<Int64>
        let flags: RawArray<UInt8>
        let childStart: RawArray<Int32>
        let childCount: RawArray<Int32>
        let nameBytes: RawArray<UInt8>
        /// 이름 순서가 시작하는 위치(파일 안)
        let orderOffset: Int
    }

    /// 압축한 뒤 저장하고, 방금 쓴 파일을 비춰 쓰도록 바꾼다(압축하며 늘었던 메모리를 돌려준다).
    public func save(to url: URL, eventId: UInt64, configHash: UInt64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock.write {
            if deletedCount > 0 || !extraChildren.isEmpty || nameOrderCoverage < parent.count { compactLocked() }
        }
        let (savedGeneration, savedEpoch): (UInt64, UInt64) = try lock.read {
            let temp = url.appendingPathExtension("tmp")
            guard let file = fopen(temp.path, "wb") else { throw CocoaError(.fileWriteUnknown) }
            var ok = true
            var written = 0
            let zeros = [UInt8](repeating: 0, count: RawArray<UInt8>.sectionAlignment)
            func put(_ pointer: UnsafeRawPointer, _ bytes: Int) {
                if bytes > 0 && fwrite(pointer, 1, bytes, file) != bytes { ok = false }
                written += bytes
            }
            // 다음 구간이 16KB 경계에서 시작하도록 0으로 채운다.
            func pad() {
                let gap = RawArray<UInt8>.aligned(written) - written
                if gap > 0 { zeros.withUnsafeBytes { put($0.baseAddress!, gap) } }
            }
            var header = Header(magic: Self.magic, version: Self.formatVersion, eventId: eventId, configHash: configHash,
                                count: UInt64(parent.count), nameBytes: UInt64(nameBytes.count),
                                orderCount: UInt64(nameOrder.count))
            withUnsafeBytes(of: &header) { put($0.baseAddress!, $0.count) }
            pad()
            let n = parent.count
            for (pointer, bytes) in [(UnsafeRawPointer(parent.pointer), n * 4), (UnsafeRawPointer(nameStart.pointer), n * 4),
                                     (UnsafeRawPointer(nameLen.pointer), n * 2), (UnsafeRawPointer(keyStart.pointer), n * 4),
                                     (UnsafeRawPointer(keyLen.pointer), n * 2), (UnsafeRawPointer(size.pointer), n * 8),
                                     (UnsafeRawPointer(mtime.pointer), n * 8), (UnsafeRawPointer(flags.pointer), n),
                                     (UnsafeRawPointer(childStart.pointer), n * 4), (UnsafeRawPointer(childCount.pointer), n * 4),
                                     (UnsafeRawPointer(nameBytes.pointer), nameBytes.count)] {
                put(pointer, bytes)
                pad()
            }
            nameOrder.withUnsafeBytes { put($0.baseAddress!, $0.count) }
            pad()
            if fclose(file) != 0 { ok = false }
            guard ok else {
                unlink(temp.path)
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(temp.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
            return (generation, layoutEpoch)
        }
        // 쓰는 동안 바뀐 것이 없으면 메모리의 배열을 방금 쓴 파일로 바꿔 끼운다(id는 그대로).
        lock.write {
            guard generation == savedGeneration, layoutEpoch == savedEpoch else { return }
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var header = Header(magic: 0, version: 0, eventId: 0, configHash: 0, count: 0, nameBytes: 0, orderCount: 0)
            guard withUnsafeMutableBytes(of: &header, { pread(fd, $0.baseAddress, $0.count, 0) == $0.count }),
                  Int(header.count) == parent.count, Int(header.nameBytes) == nameBytes.count,
                  let sections = Self.mapSections(fd: fd, header: header) else { return }
            install(sections)
        }
    }

    /// 저장된 색인을 읽는다. 형식이나 설정이 다르면 nil.
    public func load(from url: URL, expectedConfigHash: UInt64) -> UInt64? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var header = Header(magic: 0, version: 0, eventId: 0, configHash: 0, count: 0, nameBytes: 0, orderCount: 0)
        let headerOk = withUnsafeMutableBytes(of: &header) { pread(fd, $0.baseAddress, $0.count, 0) == $0.count }
        guard headerOk, header.magic == Self.magic, header.configHash == expectedConfigHash,
              header.count > 0, header.count < UInt64(Int32.max) else { return nil }

        let sections: Sections
        switch header.version {
        case Self.formatVersion:
            guard let mapped = Self.mapSections(fd: fd, header: header) else { return nil }
            sections = mapped
        case Self.legacyFormatVersion:
            guard let read = Self.readLegacySections(fd: fd, header: header) else { return nil }
            sections = read
        default:
            return nil
        }
        var order = [Int32](repeating: 0, count: Int(header.orderCount))
        let orderBytes = order.count * 4
        let orderOk = order.withUnsafeMutableBytes { orderBytes == 0 || pread(fd, $0.baseAddress, orderBytes, off_t(sections.orderOffset)) == orderBytes }
        guard orderOk else { return nil }

        let n = Int(header.count)
        lock.write {
            install(sections)
            loadedLegacyFormat = header.version == Self.legacyFormatVersion
            extraChildren = [:]
            nameOrder = order
            nameOrderCoverage = n
            deletedCount = 0
            liveCountStorage = n - 1
            layoutEpoch &+= 1
            generation &+= 1
        }
        return header.eventId
    }

    private func install(_ s: Sections) {
        parent = s.parent; nameStart = s.nameStart; nameLen = s.nameLen; keyStart = s.keyStart; keyLen = s.keyLen
        size = s.size; mtime = s.mtime; flags = s.flags; childStart = s.childStart; childCount = s.childCount
        nameBytes = s.nameBytes
    }

    /// 형식 3: 구간마다 파일을 비춰 쓴다. 실시간 반영으로 늘어날 몫(spare)만큼 주소 공간을 더 잡아 둔다.
    private static func mapSections(fd: Int32, header: Header) -> Sections? {
        let n = Int(header.count)
        let spare = max(n / 8, 65_536)
        var offset = RawArray<UInt8>.aligned(MemoryLayout<Header>.size)
        func map<T>(_: T.Type, _ count: Int, spare extra: Int = spare) -> RawArray<T>? {
            let array = RawArray<T>.mapped(fd: fd, offset: offset, count: count, spare: extra)
            offset += RawArray<UInt8>.aligned(count * MemoryLayout<T>.stride)
            return array
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        guard let p = map(Int32.self, n), let ns = map(UInt32.self, n), let nl = map(UInt16.self, n),
              let ks = map(UInt32.self, n), let kl = map(UInt16.self, n), let sz = map(Int64.self, n),
              let mt = map(Int64.self, n), let fl = map(UInt8.self, n), let cs = map(Int32.self, n),
              let cc = map(Int32.self, n), let nb = map(UInt8.self, Int(header.nameBytes), spare: Int(header.nameBytes) / 8 + (8 << 20))
        else { return nil }
        // 파일이 잘렸으면 비춘 곳을 읽다가 앱이 죽으므로 길이를 먼저 확인한다.
        guard Int(st.st_size) >= offset + RawArray<UInt8>.aligned(Int(header.orderCount) * 4) else { return nil }
        return Sections(parent: p, nameStart: ns, nameLen: nl, keyStart: ks, keyLen: kl, size: sz, mtime: mt, flags: fl,
                        childStart: cs, childCount: cc, nameBytes: nb, orderOffset: offset)
    }

    /// 형식 2: 배열이 빈틈없이 이어져 있어 비춰 쓸 수 없으므로 읽어 들인다.
    private static func readLegacySections(fd: Int32, header: Header) -> Sections? {
        let n = Int(header.count)
        var offset = MemoryLayout<Header>.size
        var ok = true
        func get<T>(_: T.Type, _ count: Int) -> RawArray<T> {
            let array = RawArray<T>(capacity: count + 16)
            array.resizeUninitialized(count)
            let bytes = count * MemoryLayout<T>.stride
            if bytes > 0 && pread(fd, array.pointer, bytes, off_t(offset)) != bytes { ok = false }
            offset += bytes
            return array
        }
        let p = get(Int32.self, n), ns = get(UInt32.self, n), nl = get(UInt16.self, n)
        let ks = get(UInt32.self, n), kl = get(UInt16.self, n)
        let sz = get(Int64.self, n), mt = get(Int64.self, n), fl = get(UInt8.self, n)
        let cs = get(Int32.self, n), cc = get(Int32.self, n)
        let nb = get(UInt8.self, Int(header.nameBytes))
        guard ok else { return nil }
        return Sections(parent: p, nameStart: ns, nameLen: nl, keyStart: ks, keyLen: kl, size: sz, mtime: mt, flags: fl,
                        childStart: cs, childCount: cc, nameBytes: nb, orderOffset: offset)
    }
}
