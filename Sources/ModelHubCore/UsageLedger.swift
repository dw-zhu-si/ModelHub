import Darwin
import Dispatch
import Foundation

/// A privacy-preserving per-request accounting row. The explicit Codable
/// allowlist is intentional: prompts, bodies, headers and credentials have no
/// representation in this type and cannot be persisted accidentally.
public struct UsageLedgerRecord: Codable, Hashable, Sendable {
    public let requestID: String
    public let timestamp: Date
    public let workspaceID: UUID?
    public let virtualKeyID: UUID?
    public let providerID: UUID
    public let credentialID: UUID?
    public let model: String
    public let statusCode: Int
    public let latencyMilliseconds: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double?

    public init(
        requestID: String,
        timestamp: Date = .now,
        workspaceID: UUID? = nil,
        virtualKeyID: UUID? = nil,
        providerID: UUID,
        credentialID: UUID? = nil,
        model: String,
        statusCode: Int,
        latencyMilliseconds: Int,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double?
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.workspaceID = workspaceID
        self.virtualKeyID = virtualKeyID
        self.providerID = providerID
        self.credentialID = credentialID
        self.model = model
        self.statusCode = max(0, statusCode)
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.estimatedCostUSD = estimatedCostUSD.flatMap {
            $0.isFinite ? max(0, $0) : nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, timestamp, workspaceID, virtualKeyID, providerID,
             credentialID, model, statusCode, latencyMilliseconds, inputTokens,
             outputTokens, estimatedCostUSD
    }
}

public struct UsageLedgerLimits: Hashable, Sendable {
    public static let hardMaximumRecordBytes = 64 * 1_024
    public static let hardMaximumShardBytes = 128 * 1_024 * 1_024
    public static let hardMaximumPageSize = 1_000
    public static let hardMaximumRetentionMonths = 120
    public static let hardMaximumWriteLockTimeoutMilliseconds = 5_000

    public let maximumRecordBytes: Int
    public let maximumShardBytes: Int
    public let maximumPageSize: Int
    public let retentionMonths: Int
    public let writeLockTimeoutMilliseconds: Int

    public init(
        maximumRecordBytes: Int = 16 * 1_024,
        maximumShardBytes: Int = 64 * 1_024 * 1_024,
        maximumPageSize: Int = 500,
        retentionMonths: Int = 12,
        writeLockTimeoutMilliseconds: Int = 250
    ) {
        self.maximumRecordBytes = min(
            max(1, maximumRecordBytes),
            Self.hardMaximumRecordBytes
        )
        self.maximumShardBytes = min(
            max(1, maximumShardBytes),
            Self.hardMaximumShardBytes
        )
        self.maximumPageSize = min(
            max(1, maximumPageSize),
            Self.hardMaximumPageSize
        )
        self.retentionMonths = min(
            max(1, retentionMonths),
            Self.hardMaximumRetentionMonths
        )
        self.writeLockTimeoutMilliseconds = min(
            max(1, writeLockTimeoutMilliseconds),
            Self.hardMaximumWriteLockTimeoutMilliseconds
        )
    }
}

public struct UsageLedgerCursor: Codable, Hashable, Sendable {
    public let month: String
    /// Opaque, versioned continuation token. Callers must round-trip this
    /// value without attempting to interpret its byte-offset payload.
    public let opaqueValue: String?
    /// Compatibility bridge for clients which persisted the pre-1.10 line
    /// cursor. New pages always include `opaqueValue`; this field is retained
    /// in memory so older API surfaces can migrate without skipping records.
    public let lineOffset: Int

    public init(month: String, lineOffset: Int) {
        self.month = month
        self.opaqueValue = nil
        self.lineOffset = lineOffset
    }

    public init(month: String, opaqueValue: String) {
        self.month = month
        self.opaqueValue = opaqueValue
        self.lineOffset = -1
    }

    init(month: String, opaqueByteOffset: UInt64, legacyLineOffset: Int) {
        self.month = month
        self.opaqueValue = Self.encodeOpaqueValue(
            byteOffset: opaqueByteOffset,
            lineOffset: legacyLineOffset
        )
        self.lineOffset = legacyLineOffset
    }

    private enum CodingKeys: String, CodingKey {
        case month
        case cursor
        case lineOffset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        month = try container.decode(String.self, forKey: .month)
        opaqueValue = try container.decodeIfPresent(String.self, forKey: .cursor)
        lineOffset = try container.decodeIfPresent(Int.self, forKey: .lineOffset) ?? -1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(month, forKey: .month)
        if let opaqueValue {
            try container.encode(opaqueValue, forKey: .cursor)
        } else {
            try container.encode(lineOffset, forKey: .lineOffset)
        }
    }

    fileprivate func decodedOpaquePosition() -> (byteOffset: UInt64, lineOffset: Int)? {
        guard let opaqueValue,
              let data = Data(base64URLEncoded: opaqueValue),
              data.count == 17,
              data[data.startIndex] == 1
        else { return nil }

        var byteOffset: UInt64 = 0
        var encodedLineOffset: UInt64 = 0
        for byte in data.dropFirst().prefix(8) {
            byteOffset = (byteOffset << 8) | UInt64(byte)
        }
        for byte in data.dropFirst(9).prefix(8) {
            encodedLineOffset = (encodedLineOffset << 8) | UInt64(byte)
        }
        guard encodedLineOffset < UInt64(Int.max),
              encodedLineOffset <= byteOffset
        else { return nil }
        return (byteOffset, Int(encodedLineOffset))
    }

    private static func encodeOpaqueValue(
        byteOffset: UInt64,
        lineOffset: Int
    ) -> String {
        precondition(lineOffset >= 0)
        var data = Data([1])
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((byteOffset >> UInt64(shift)) & 0xFF))
        }
        let unsignedLineOffset = UInt64(lineOffset)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((unsignedLineOffset >> UInt64(shift)) & 0xFF))
        }
        return data.base64URLEncodedString()
    }
}

public struct UsageLedgerPage: Hashable, Sendable {
    public let records: [UsageLedgerRecord]
    public let nextCursor: UsageLedgerCursor?

    public init(records: [UsageLedgerRecord], nextCursor: UsageLedgerCursor?) {
        self.records = records
        self.nextCursor = nextCursor
    }
}

public enum UsageLedgerError: Error, Equatable, Sendable {
    case invalidMonth(String)
    case invalidCursor
    case invalidPageLimit(maximum: Int)
    case recordTooLarge(maximum: Int)
    case shardTooLarge(month: String, maximum: Int)
    case corruptedLine(month: String, line: Int)
    case lockTimedOut(milliseconds: Int)
    case ioFailure(operation: String, code: Int32)
}

extension UsageLedgerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMonth(let month):
            return "无效的用量月份：\(month)"
        case .invalidCursor:
            return "用量查询游标与当前月份不匹配"
        case .invalidPageLimit(let maximum):
            return "用量查询分页数必须为 1...\(maximum)"
        case .recordTooLarge(let maximum):
            return "单条用量记录超过 \(maximum) 字节上限"
        case .shardTooLarge(let month, let maximum):
            return "\(month) 用量分片超过 \(maximum) 字节上限"
        case .corruptedLine(let month, let line):
            return "\(month) 用量分片第 \(line) 行损坏"
        case .lockTimedOut(let milliseconds):
            return "用量账本写锁在 \(milliseconds) 毫秒内未可用"
        case .ioFailure(let operation, let code):
            return "用量账本 \(operation) 失败（\(code)）"
        }
    }
}

/// A process-local actor plus an advisory file lock serializes appends. Each
/// JSONL row is submitted with one O_APPEND write so multiple store instances
/// cannot overwrite one another's offsets.
public actor UsageLedgerStore {
    private static let processWriteLock = NSLock()

    public let directoryURL: URL
    public let limits: UsageLedgerLimits
    private let lockAttempt: @Sendable (Int32) -> UsageLedgerLockAttemptResult

    public init(
        directoryURL: URL,
        limits: UsageLedgerLimits = .init()
    ) {
        self.directoryURL = directoryURL
        self.limits = limits
        self.lockAttempt = Self.attemptPOSIXWriteLock
    }

    init(
        directoryURL: URL,
        limits: UsageLedgerLimits = .init(),
        lockAttemptForTesting: @escaping @Sendable (Int32) -> UsageLedgerLockAttemptResult
    ) {
        self.directoryURL = directoryURL
        self.limits = limits
        self.lockAttempt = lockAttemptForTesting
    }

    public static func defaultApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "ModelHub/UsageLedger", directoryHint: .isDirectory)
    }

    public func append(_ record: UsageLedgerRecord) throws {
        let month = UsageMonth(date: record.timestamp).key
        let encoded = try Self.encoder().encode(record)
        guard encoded.count <= limits.maximumRecordBytes else {
            throw UsageLedgerError.recordTooLarge(maximum: limits.maximumRecordBytes)
        }

        try ensureDirectoryReady(createIfMissing: true)
        var line = encoded
        line.append(0x0A)
        try appendLine(line, month: month)
    }

    public func query(
        month: String,
        cursor: UsageLedgerCursor? = nil,
        limit: Int = 100
    ) throws -> UsageLedgerPage {
        guard Self.isValidMonth(month) else {
            throw UsageLedgerError.invalidMonth(month)
        }
        guard (1...limits.maximumPageSize).contains(limit) else {
            throw UsageLedgerError.invalidPageLimit(maximum: limits.maximumPageSize)
        }
        if let cursor {
            guard cursor.month == month,
                  cursor.opaqueValue != nil || cursor.lineOffset >= 0
            else {
                throw UsageLedgerError.invalidCursor
            }
        }

        try ensureDirectoryReady(createIfMissing: false)
        let url = shardURL(month: month)
        guard let descriptor = try openShardForReading(url: url) else {
            return UsageLedgerPage(records: [], nextCursor: nil)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw UsageLedgerError.ioFailure(operation: "stat", code: Int32(errno))
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw UsageLedgerError.ioFailure(operation: "stat", code: EINVAL)
        }
        let shardBytes = UInt64(max(0, information.st_size))
        guard shardBytes <= UInt64(limits.maximumShardBytes) else {
            throw UsageLedgerError.shardTooLarge(
                month: month,
                maximum: limits.maximumShardBytes
            )
        }

        let position: (byteOffset: UInt64, lineOffset: Int)
        do {
            position = try startingPosition(
                cursor: cursor,
                descriptor: descriptor,
                handle: handle,
                shardBytes: shardBytes
            )
            try handle.seek(toOffset: position.byteOffset)
        } catch let error as UsageLedgerError {
            throw error
        } catch {
            throw UsageLedgerError.ioFailure(
                operation: "read",
                code: Self.posixCode(for: error)
            )
        }

        var records: [UsageLedgerRecord] = []
        records.reserveCapacity(limit)
        var nextCursor: UsageLedgerCursor?
        let decoder = Self.decoder()
        var scanner = UsageLedgerLineScanner(
            handle: handle,
            startingByteOffset: position.byteOffset,
            startingLineOffset: position.lineOffset,
            maximumRecordBytes: limits.maximumRecordBytes
        )

        do {
            while let line = try scanner.nextLine() {
                if line.data.isEmpty {
                    throw UsageLedgerError.corruptedLine(
                        month: month,
                        line: line.lineOffset + 1
                    )
                }

                let record: UsageLedgerRecord
                do {
                    record = try decoder.decode(UsageLedgerRecord.self, from: line.data)
                } catch {
                    if !line.isNewlineTerminated {
                        // An interrupted append can only exist at EOF. It is
                        // ignored until a later append either completes it or
                        // truncates it while holding the write lock.
                        break
                    }
                    throw UsageLedgerError.corruptedLine(
                        month: month,
                        line: line.lineOffset + 1
                    )
                }

                if records.count == limit {
                    nextCursor = UsageLedgerCursor(
                        month: month,
                        opaqueByteOffset: line.byteOffset,
                        legacyLineOffset: line.lineOffset
                    )
                    break
                }
                records.append(record)
            }
        } catch let error as UsageLedgerError {
            throw error
        } catch {
            throw UsageLedgerError.ioFailure(
                operation: "read",
                code: Self.posixCode(for: error)
            )
        }

        return UsageLedgerPage(records: records, nextCursor: nextCursor)
    }

    /// Removes only ledger files whose entire UTC month is outside retention.
    /// Unrelated files and current/future month shards are left untouched.
    @discardableResult
    public func prune(referenceDate: Date = .now) throws -> [String] {
        try ensureDirectoryReady(createIfMissing: true)
        let currentMonth = UsageMonth(date: referenceDate)
        let cutoff = currentMonth.adding(months: -(limits.retentionMonths - 1)).key
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var removed: [String] = []
        for url in urls {
            guard let month = Self.monthFromShardFilename(url.lastPathComponent),
                  month < cutoff
            else { continue }
            try FileManager.default.removeItem(at: url)
            removed.append(month)
        }
        return removed.sorted()
    }

    private func appendLine(_ line: Data, month: String) throws {
        let url = shardURL(month: month)
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw UsageLedgerError.ioFailure(operation: "open", code: Int32(errno))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw UsageLedgerError.ioFailure(
                operation: "permissions",
                code: Int32(errno)
            )
        }

        try acquireProcessWriteLock()
        defer { Self.processWriteLock.unlock() }
        try acquireWriteLock(descriptor)
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw UsageLedgerError.ioFailure(operation: "stat", code: Int32(errno))
        }
        let originalBytes = max(0, Int(information.st_size))
        guard originalBytes <= limits.maximumShardBytes else {
            throw UsageLedgerError.shardTooLarge(
                month: month,
                maximum: limits.maximumShardBytes
            )
        }
        let existingBytes = try repairInterruptedTrailingLine(
            descriptor: descriptor,
            existingBytes: originalBytes
        )
        guard existingBytes <= limits.maximumShardBytes - line.count else {
            throw UsageLedgerError.shardTooLarge(
                month: month,
                maximum: limits.maximumShardBytes
            )
        }

        do {
            try line.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        throw UsageLedgerError.ioFailure(
                            operation: "write",
                            code: Int32(errno)
                        )
                    }
                }
            }
        } catch {
            // Keep a failed append recoverable as a trailing-line event rather
            // than leaving a partial row that could corrupt every later page.
            _ = Darwin.ftruncate(descriptor, off_t(existingBytes))
            throw error
        }
    }

    /// An O_APPEND write is protected by a cross-process record lock, but a
    /// process can still be terminated between partial write syscalls. Before
    /// the next append, discard only that unterminated tail while retaining
    /// every complete JSONL row preceding it.
    private func repairInterruptedTrailingLine(
        descriptor: Int32,
        existingBytes: Int
    ) throws -> Int {
        guard existingBytes > 0 else { return 0 }
        var finalByte: UInt8 = 0
        let finalRead = withUnsafeMutablePointer(to: &finalByte) {
            Darwin.pread(descriptor, $0, 1, off_t(existingBytes - 1))
        }
        guard finalRead == 1 else {
            throw UsageLedgerError.ioFailure(operation: "read", code: Int32(errno))
        }
        guard finalByte != 0x0A else { return existingBytes }

        let searchBytes = min(existingBytes, limits.maximumRecordBytes + 1)
        var tail = Data(count: searchBytes)
        let tailRead = tail.withUnsafeMutableBytes { bytes in
            Darwin.pread(
                descriptor,
                bytes.baseAddress,
                bytes.count,
                off_t(existingBytes - searchBytes)
            )
        }
        guard tailRead == searchBytes else {
            throw UsageLedgerError.ioFailure(operation: "read", code: Int32(errno))
        }

        let repairedBytes: Int
        if let newlineIndex = tail.lastIndex(of: 0x0A) {
            repairedBytes = existingBytes - searchBytes
                + tail.distance(from: tail.startIndex, to: newlineIndex) + 1
        } else if existingBytes <= limits.maximumRecordBytes {
            repairedBytes = 0
        } else {
            throw UsageLedgerError.recordTooLarge(maximum: limits.maximumRecordBytes)
        }
        guard Darwin.ftruncate(descriptor, off_t(repairedBytes)) == 0 else {
            throw UsageLedgerError.ioFailure(operation: "truncate", code: Int32(errno))
        }
        return repairedBytes
    }

    private func ensureDirectoryReady(createIfMissing: Bool) throws {
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw UsageLedgerError.ioFailure(
                    operation: "directory",
                    code: Self.posixCode(for: error)
                )
            }
        }

        var information = stat()
        guard Darwin.lstat(directoryURL.path, &information) == 0 else {
            if !createIfMissing, errno == ENOENT { return }
            throw UsageLedgerError.ioFailure(
                operation: "directory",
                code: Int32(errno)
            )
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            let code: Int32 = information.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
                ? ELOOP
                : ENOTDIR
            throw UsageLedgerError.ioFailure(operation: "directory", code: code)
        }
        guard Darwin.chmod(directoryURL.path, S_IRWXU) == 0 else {
            throw UsageLedgerError.ioFailure(
                operation: "permissions",
                code: Int32(errno)
            )
        }
    }

    private func openShardForReading(url: URL) throws -> Int32? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw UsageLedgerError.ioFailure(operation: "open", code: Int32(errno))
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = Int32(errno)
            Darwin.close(descriptor)
            throw UsageLedgerError.ioFailure(operation: "permissions", code: code)
        }
        return descriptor
    }

    private func startingPosition(
        cursor: UsageLedgerCursor?,
        descriptor: Int32,
        handle: FileHandle,
        shardBytes: UInt64
    ) throws -> (byteOffset: UInt64, lineOffset: Int) {
        guard let cursor else { return (0, 0) }
        if cursor.opaqueValue != nil {
            guard let position = cursor.decodedOpaquePosition(),
                  position.byteOffset <= shardBytes,
                  isLineBoundary(descriptor: descriptor, byteOffset: position.byteOffset)
            else { throw UsageLedgerError.invalidCursor }
            return position
        }

        guard cursor.lineOffset >= 0 else { throw UsageLedgerError.invalidCursor }
        try handle.seek(toOffset: 0)
        var scanner = UsageLedgerLineScanner(
            handle: handle,
            startingByteOffset: 0,
            startingLineOffset: 0,
            maximumRecordBytes: limits.maximumRecordBytes
        )
        var consumedLines = 0
        var byteOffset: UInt64 = 0
        while consumedLines < cursor.lineOffset {
            guard let line = try scanner.nextLine() else {
                throw UsageLedgerError.invalidCursor
            }
            consumedLines += 1
            byteOffset = line.nextByteOffset
        }
        guard byteOffset <= shardBytes else { throw UsageLedgerError.invalidCursor }
        return (byteOffset, cursor.lineOffset)
    }

    private func isLineBoundary(descriptor: Int32, byteOffset: UInt64) -> Bool {
        guard byteOffset > 0 else { return true }
        var precedingByte: UInt8 = 0
        let readCount = withUnsafeMutablePointer(to: &precedingByte) {
            Darwin.pread(descriptor, $0, 1, off_t(byteOffset - 1))
        }
        return readCount == 1 && precedingByte == 0x0A
    }

    private func acquireWriteLock(_ descriptor: Int32) throws {
        let timeoutMilliseconds = limits.writeLockTimeoutMilliseconds
        let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started.addingReportingOverflow(timeoutNanoseconds)
        let deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue

        while true {
            switch lockAttempt(descriptor) {
            case .acquired:
                return
            case .failed(let code):
                throw UsageLedgerError.ioFailure(operation: "lock", code: code)
            case .contended:
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadlineNanoseconds else {
                    throw UsageLedgerError.lockTimedOut(
                        milliseconds: timeoutMilliseconds
                    )
                }
                let remainingNanoseconds = deadlineNanoseconds - now
                let sleepMicroseconds = useconds_t(
                    max(1, min(5_000, remainingNanoseconds / 1_000))
                )
                Darwin.usleep(sleepMicroseconds)
            }
        }
    }

    private func acquireProcessWriteLock() throws {
        let timeoutMilliseconds = limits.writeLockTimeoutMilliseconds
        let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started.addingReportingOverflow(timeoutNanoseconds)
        let deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue

        while !Self.processWriteLock.try() {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineNanoseconds else {
                throw UsageLedgerError.lockTimedOut(milliseconds: timeoutMilliseconds)
            }
            let remainingNanoseconds = deadlineNanoseconds - now
            Darwin.usleep(
                useconds_t(max(1, min(5_000, remainingNanoseconds / 1_000)))
            )
        }
    }

    private nonisolated static func attemptPOSIXWriteLock(
        descriptor: Int32
    ) -> UsageLedgerLockAttemptResult {
        var writeLock = flock()
        writeLock.l_type = Int16(F_WRLCK)
        writeLock.l_whence = Int16(SEEK_SET)
        while true {
            if Darwin.fcntl(descriptor, F_SETLK, &writeLock) == 0 {
                return .acquired
            }
            let code = Int32(errno)
            if code == EINTR { continue }
            if code == EACCES || code == EAGAIN { return .contended }
            return .failed(code)
        }
    }

    private nonisolated static func posixCode(for error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(clamping: nsError.code)
        }
        return EIO
    }

    private func shardURL(month: String) -> URL {
        directoryURL.appending(path: "usage-\(month).jsonl")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func isValidMonth(_ month: String) -> Bool {
        let characters = Array(month)
        guard characters.count == 7,
              characters[4] == "-",
              characters.enumerated().allSatisfy({ index, character in
                  index == 4 || character.isNumber
              }),
              let numericMonth = Int(String(characters[5...6])),
              (1...12).contains(numericMonth)
        else { return false }
        return true
    }

    private static func monthFromShardFilename(_ filename: String) -> String? {
        let prefix = "usage-"
        let suffix = ".jsonl"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let month = String(filename[start..<end])
        return isValidMonth(month) ? month : nil
    }
}

enum UsageLedgerLockAttemptResult: Equatable, Sendable {
    case acquired
    case contended
    case failed(Int32)
}

private struct UsageLedgerScannedLine {
    let data: Data
    let byteOffset: UInt64
    let nextByteOffset: UInt64
    let lineOffset: Int
    let isNewlineTerminated: Bool
}

private struct UsageLedgerLineScanner {
    private static let chunkBytes = 64 * 1_024

    private let handle: FileHandle
    private let maximumRecordBytes: Int
    private var buffer = Data()
    private var bufferStartIndex = 0
    private var bufferByteOffset: UInt64
    private var nextLineOffset: Int
    private var reachedEOF = false

    init(
        handle: FileHandle,
        startingByteOffset: UInt64,
        startingLineOffset: Int,
        maximumRecordBytes: Int
    ) {
        self.handle = handle
        self.bufferByteOffset = startingByteOffset
        self.nextLineOffset = startingLineOffset
        self.maximumRecordBytes = maximumRecordBytes
    }

    mutating func nextLine() throws -> UsageLedgerScannedLine? {
        while true {
            if let newlineIndex = buffer[bufferStartIndex...].firstIndex(of: 0x0A) {
                let lineByteCount = buffer.distance(
                    from: bufferStartIndex,
                    to: newlineIndex
                )
                guard lineByteCount <= maximumRecordBytes else {
                    throw UsageLedgerError.recordTooLarge(maximum: maximumRecordBytes)
                }
                let line = UsageLedgerScannedLine(
                    data: Data(buffer[bufferStartIndex..<newlineIndex]),
                    byteOffset: bufferByteOffset,
                    nextByteOffset: bufferByteOffset + UInt64(lineByteCount + 1),
                    lineOffset: nextLineOffset,
                    isNewlineTerminated: true
                )
                bufferStartIndex = buffer.index(after: newlineIndex)
                bufferByteOffset = line.nextByteOffset
                nextLineOffset += 1
                return line
            }

            let pendingByteCount = buffer.distance(
                from: bufferStartIndex,
                to: buffer.endIndex
            )
            if reachedEOF {
                guard pendingByteCount > 0 else { return nil }
                guard pendingByteCount <= maximumRecordBytes else {
                    throw UsageLedgerError.recordTooLarge(maximum: maximumRecordBytes)
                }
                let line = UsageLedgerScannedLine(
                    data: Data(buffer[bufferStartIndex...]),
                    byteOffset: bufferByteOffset,
                    nextByteOffset: bufferByteOffset + UInt64(pendingByteCount),
                    lineOffset: nextLineOffset,
                    isNewlineTerminated: false
                )
                bufferStartIndex = buffer.endIndex
                bufferByteOffset = line.nextByteOffset
                nextLineOffset += 1
                return line
            }
            guard pendingByteCount <= maximumRecordBytes else {
                throw UsageLedgerError.recordTooLarge(maximum: maximumRecordBytes)
            }

            if bufferStartIndex > 0 {
                buffer = Data(buffer[bufferStartIndex...])
                bufferStartIndex = buffer.startIndex
            }
            let chunk = try handle.read(upToCount: Self.chunkBytes) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
