import Foundation

/// 단순 값(Int32, UInt8 등)만 담는 늘어나는 배열.
/// 검색 루프에서 포인터를 바로 써서 경계 검사와 ARC 비용을 없앤다.
/// 저장본 파일을 복사하지 않고 비춰 쓸 수도 있다(mapped). 그때는 고친 쪽만 메모리를 차지한다.
final class RawArray<T> {
    private(set) var pointer: UnsafeMutablePointer<T>
    private(set) var count = 0
    private(set) var capacity: Int
    /// 0이면 malloc으로 잡은 배열, 아니면 mmap으로 잡은 영역(익명 또는 저장본 비추기)의 바이트 수
    private var mappedBytes = 0

    init(capacity: Int = 1024) {
        self.capacity = max(capacity, 16)
        (pointer, mappedBytes) = Self.allocateStorage(self.capacity)
    }

    /// 1MB 이상은 mmap으로 잡는다. malloc으로 잡은 큰 덩어리는 해제해도 프로세스 몫으로 남지만(이 macOS의 할당기),
    /// munmap한 메모리는 바로 시스템에 돌아간다. 압축·다시 훑기로 잠깐 커졌던 배열이 앱 메모리에 눌러앉지 않게 한다.
    private static func allocateStorage(_ capacity: Int) -> (UnsafeMutablePointer<T>, Int) {
        let bytes = capacity * MemoryLayout<T>.stride
        if bytes >= 1 << 20 {
            let total = aligned(bytes)
            if let base = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), base != MAP_FAILED {
                return (base.bindMemory(to: T.self, capacity: capacity), total)
            }
        }
        return (UnsafeMutablePointer<T>.allocate(capacity: capacity), 0)
    }

    private init(mapped base: UnsafeMutableRawPointer, count: Int, bytes: Int) {
        capacity = bytes / MemoryLayout<T>.stride
        pointer = base.bindMemory(to: T.self, capacity: capacity)
        self.count = count
        mappedBytes = bytes
    }

    deinit { release() }

    private func release() {
        if mappedBytes > 0 { munmap(UnsafeMutableRawPointer(pointer), mappedBytes) } else { pointer.deallocate() }
    }

    /// 저장본에서 구간을 16KB 단위로 맞춘다(mmap은 페이지 경계에서만 시작할 수 있다).
    static var sectionAlignment: Int { 16_384 }

    static func aligned(_ bytes: Int) -> Int {
        (bytes + sectionAlignment - 1) / sectionAlignment * sectionAlignment
    }

    /// 파일 fd의 offset부터 count개를 복사하지 않고 비춰 쓴다(MAP_PRIVATE: 고친 페이지만 따로 메모리를 잡는다).
    /// 뒤에 spare개를 덧붙일 수 있게 주소 공간을 넉넉히 잡아 둔다. 실제로 쓰기 전에는 메모리를 차지하지 않는다.
    /// 파일은 이 구간 뒤를 16KB 경계까지 채워 두어야 한다.
    static func mapped(fd: Int32, offset: Int, count: Int, spare: Int) -> RawArray<T>? {
        let stride = MemoryLayout<T>.stride
        let fileBytes = aligned(count * stride)
        let total = aligned(max((count + spare) * stride, fileBytes, sectionAlignment))
        guard let base = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), base != MAP_FAILED else { return nil }
        if fileBytes > 0 {
            let file = mmap(base, fileBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, fd, off_t(offset))
            guard file != MAP_FAILED else {
                munmap(base, total)
                return nil
            }
        }
        return RawArray(mapped: base, count: count, bytes: total)
    }

    @inline(__always) subscript(i: Int) -> T {
        get { pointer[i] }
        set { pointer[i] = newValue }
    }

    func reserve(_ needed: Int) {
        guard needed > capacity else { return }
        var newCapacity = capacity
        while newCapacity < needed { newCapacity = newCapacity + newCapacity / 2 + 16 }
        let (newPointer, newMappedBytes) = Self.allocateStorage(newCapacity)
        newPointer.moveInitialize(from: pointer, count: count)
        release()
        mappedBytes = newMappedBytes
        pointer = newPointer
        capacity = newCapacity
    }

    @inline(__always) func append(_ value: T) {
        if count == capacity { reserve(count + 1) }
        (pointer + count).initialize(to: value)
        count += 1
    }

    func append(contentsOf buffer: UnsafeBufferPointer<T>) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        reserve(count + buffer.count)
        (pointer + count).initialize(from: base, count: buffer.count)
        count += buffer.count
    }

    func append(contentsOf array: [T]) {
        array.withUnsafeBufferPointer { append(contentsOf: $0) }
    }

    /// 파일에서 읽을 때 쓴다. 내용은 호출한 쪽이 채운다.
    func resizeUninitialized(_ newCount: Int) {
        reserve(newCount)
        count = newCount
    }
}

/// 읽기는 여럿이 동시에, 쓰기는 혼자 하는 잠금.
final class RWLock {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    @inline(__always) func read<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    @inline(__always) func write<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
}

/// 검색을 중간에 그만두게 하는 표식.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

enum TextKey {
    /// 검색 키: 유니코드 NFC + 소문자. 맥 파일 이름의 한글은 NFD(자모 분리)로 저장된 경우가 많아서
    /// 사용자가 입력한 NFC 검색어와 맞추려면 이 정규화가 꼭 필요하다.
    static func append(keyOf name: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) {
        var ascii = true
        for byte in name where byte >= 0x80 { ascii = false; break }
        if ascii {
            for byte in name {
                out.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
            }
        } else {
            out.append(contentsOf: key(String(decoding: name, as: UTF8.self)))
        }
    }

    static func key(_ text: String) -> [UInt8] {
        Array(text.precomposedStringWithCanonicalMapping.lowercased().utf8)
    }
}

/// 디렉터리 하나를 읽은 결과. 항목마다 배열을 따로 만들지 않도록 바이트를 한 줄로 이어 담는다.
struct EntryBatch {
    var nameBytes: [UInt8] = []
    var keyBytes: [UInt8] = []
    var nameEnds: [Int] = []
    var keyEnds: [Int] = []
    var flags: [UInt8] = []
    var sizes: [Int64] = []
    var mtimes: [Int64] = []

    var count: Int { flags.count }

    mutating func removeAll() {
        nameBytes.removeAll(keepingCapacity: true)
        keyBytes.removeAll(keepingCapacity: true)
        nameEnds.removeAll(keepingCapacity: true)
        keyEnds.removeAll(keepingCapacity: true)
        flags.removeAll(keepingCapacity: true)
        sizes.removeAll(keepingCapacity: true)
        mtimes.removeAll(keepingCapacity: true)
    }

    mutating func append(name: UnsafeBufferPointer<UInt8>, flags entryFlags: UInt8, size: Int64, mtime: Int64) {
        nameBytes.append(contentsOf: name)
        nameEnds.append(nameBytes.count)
        TextKey.append(keyOf: name, to: &keyBytes)
        keyEnds.append(keyBytes.count)
        flags.append(entryFlags)
        sizes.append(size)
        mtimes.append(mtime)
    }

    func nameRange(_ i: Int) -> Range<Int> {
        (i == 0 ? 0 : nameEnds[i - 1])..<nameEnds[i]
    }

    func keyRange(_ i: Int) -> Range<Int> {
        (i == 0 ? 0 : keyEnds[i - 1])..<keyEnds[i]
    }

    func name(_ i: Int) -> String {
        String(decoding: nameBytes[nameRange(i)], as: UTF8.self)
    }
}
