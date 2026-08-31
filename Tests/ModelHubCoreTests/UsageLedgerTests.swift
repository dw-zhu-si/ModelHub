import Darwin
import Foundation
import XCTest
@testable import ModelHubCore

final class UsageLedgerTests: XCTestCase {
    private let january = Date(timeIntervalSince1970: 1_767_225_600)
    private let february = Date(timeIntervalSince1970: 1_769_904_000)
    private let march = Date(timeIntervalSince1970: 1_772_323_200)

    func testRecordEncodingUsesAnExplicitPrivacyPreservingFieldAllowlist() throws {
        let record = makeRecord(requestID: "request-1", date: january)

        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "requestID", "timestamp", "workspaceID", "virtualKeyID", "providerID",
            "credentialID", "model", "statusCode", "latencyMilliseconds",
            "inputTokens", "outputTokens", "estimatedCostUSD"
        ])
        for forbidden in [
            "prompt", "body", "headers", "authorization", "token", "secret", "apiKey"
        ] {
            XCTAssertNil(object[forbidden])
        }
    }

    func testRecordsAreAppendedToUTCMonthlyJSONLShards() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)

        try await store.append(makeRecord(requestID: "jan", date: january))
        try await store.append(makeRecord(requestID: "feb", date: february))

        let januaryPage = try await store.query(month: "2026-01", limit: 100)
        let februaryPage = try await store.query(month: "2026-02", limit: 100)
        XCTAssertEqual(januaryPage.records.map(\.requestID), ["jan"])
        XCTAssertEqual(februaryPage.records.map(\.requestID), ["feb"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "usage-2026-01.jsonl").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "usage-2026-02.jsonl").path
            )
        )
    }

    func testQueryPaginatesWithoutDuplicatesOrSkippingRecords() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)
        for index in 0..<5 {
            try await store.append(makeRecord(requestID: "request-\(index)", date: january))
        }

        let first = try await store.query(month: "2026-01", limit: 2)
        let second = try await store.query(
            month: "2026-01",
            cursor: try XCTUnwrap(first.nextCursor),
            limit: 2
        )
        let third = try await store.query(
            month: "2026-01",
            cursor: try XCTUnwrap(second.nextCursor),
            limit: 2
        )

        XCTAssertEqual(first.records.map(\.requestID), ["request-0", "request-1"])
        XCTAssertEqual(second.records.map(\.requestID), ["request-2", "request-3"])
        XCTAssertEqual(third.records.map(\.requestID), ["request-4"])
        XCTAssertNil(third.nextCursor)
        XCTAssertNotNil(first.nextCursor?.opaqueValue)
        XCTAssertNotNil(second.nextCursor?.opaqueValue)
    }

    func testOpaqueCursorResumesAtByteOffsetAndLegacyLineCursorStillWorks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)
        for index in 0..<5 {
            try await store.append(makeRecord(requestID: "cursor-\(index)", date: january))
        }

        let first = try await store.query(month: "2026-01", limit: 2)
        let generated = try XCTUnwrap(first.nextCursor)
        let opaqueValue = try XCTUnwrap(generated.opaqueValue)
        let opaquePage = try await store.query(
            month: "2026-01",
            cursor: UsageLedgerCursor(month: "2026-01", opaqueValue: opaqueValue),
            limit: 2
        )
        let legacyPage = try await store.query(
            month: "2026-01",
            cursor: UsageLedgerCursor(month: "2026-01", lineOffset: 2),
            limit: 2
        )

        XCTAssertEqual(opaquePage.records.map(\.requestID), ["cursor-2", "cursor-3"])
        XCTAssertEqual(legacyPage.records.map(\.requestID), ["cursor-2", "cursor-3"])

        let encoded = try JSONEncoder().encode(generated)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["month"] as? String, "2026-01")
        XCTAssertEqual(object["cursor"] as? String, opaqueValue)
        XCTAssertNil(object["lineOffset"])

        let legacyJSON = Data(#"{"month":"2026-01","lineOffset":2}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(UsageLedgerCursor.self, from: legacyJSON)
        let decodedLegacyPage = try await store.query(
            month: "2026-01",
            cursor: decodedLegacy,
            limit: 2
        )
        XCTAssertEqual(decodedLegacyPage.records.map(\.requestID), ["cursor-2", "cursor-3"])
    }

    func testOpaqueCursorRejectsMalformedAndNonBoundaryOffsets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)
        try await store.append(makeRecord(requestID: "valid", date: january))

        for cursor in [
            UsageLedgerCursor(month: "2026-01", opaqueValue: "not-base64"),
            UsageLedgerCursor(
                month: "2026-01",
                opaqueByteOffset: 1,
                legacyLineOffset: 0
            )
        ] {
            do {
                _ = try await store.query(month: "2026-01", cursor: cursor, limit: 1)
                XCTFail("opaque cursors must reference a validated line boundary")
            } catch {
                XCTAssertEqual(error as? UsageLedgerError, .invalidCursor)
            }
        }
    }

    func testConcurrentAppendsAreSerializedAndProduceWholeLines() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = UsageLedgerStore(
            directoryURL: directory,
            limits: .init(maximumShardBytes: 2_000_000)
        )
        let secondStore = UsageLedgerStore(
            directoryURL: directory,
            limits: .init(maximumShardBytes: 2_000_000)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                let record = makeRecord(requestID: "concurrent-\(index)", date: january)
                let store = index.isMultiple(of: 2) ? firstStore : secondStore
                group.addTask {
                    try await store.append(record)
                }
            }
            try await group.waitForAll()
        }

        let page = try await firstStore.query(month: "2026-01", limit: 200)
        XCTAssertEqual(page.records.count, 100)
        XCTAssertEqual(Set(page.records.map(\.requestID)).count, 100)
        XCTAssertNil(page.nextCursor)
    }

    func testDirectoryAndExistingShardPermissionsAreRestricted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)

        try await store.append(makeRecord(requestID: "first", date: january))

        let shard = directory.appending(path: "usage-2026-01.jsonl")
        XCTAssertEqual(try permissionBits(at: directory), 0o700)
        XCTAssertEqual(try permissionBits(at: shard), 0o600)

        XCTAssertEqual(Darwin.chmod(shard.path, 0o644), 0)
        try await store.append(makeRecord(requestID: "second", date: january))
        XCTAssertEqual(try permissionBits(at: shard), 0o600)
    }

    func testShardSymlinkIsNeverFollowedForAppendOrQuery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "outside.jsonl")
        let original = Data("do-not-touch".utf8)
        try original.write(to: target)
        let shard = directory.appending(path: "usage-2026-01.jsonl")
        try FileManager.default.createSymbolicLink(at: shard, withDestinationURL: target)
        let store = UsageLedgerStore(directoryURL: directory)

        do {
            try await store.append(makeRecord(requestID: "blocked", date: january))
            XCTFail("append must not follow a shard symlink")
        } catch {
            XCTAssertEqual(
                error as? UsageLedgerError,
                .ioFailure(operation: "open", code: ELOOP)
            )
        }
        do {
            _ = try await store.query(month: "2026-01", limit: 1)
            XCTFail("query must not follow a shard symlink")
        } catch {
            XCTAssertEqual(
                error as? UsageLedgerError,
                .ioFailure(operation: "open", code: ELOOP)
            )
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testContendedWriteLockTimesOutInsteadOfBlockingForever() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shard = directory.appending(path: "usage-2026-01.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: shard.path, contents: nil))

        let timeoutMilliseconds = 80
        let store = UsageLedgerStore(
            directoryURL: directory,
            limits: .init(writeLockTimeoutMilliseconds: timeoutMilliseconds),
            lockAttemptForTesting: { _ in .contended }
        )

        let started = ContinuousClock.now
        do {
            try await store.append(makeRecord(requestID: "timeout", date: january))
            XCTFail("a contended cross-process lock should time out")
        } catch {
            XCTAssertEqual(
                error as? UsageLedgerError,
                .lockTimedOut(milliseconds: timeoutMilliseconds)
            )
        }
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(500))
    }

    func testRetentionRemovesOnlyWholeExpiredMonthShards() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(
            directoryURL: directory,
            limits: .init(retentionMonths: 2)
        )
        try await store.append(makeRecord(requestID: "jan", date: january))
        try await store.append(makeRecord(requestID: "feb", date: february))
        try await store.append(makeRecord(requestID: "mar", date: march))
        let unrelated = directory.appending(path: "keep-me.txt")
        try Data("unrelated".utf8).write(to: unrelated)

        let removed = try await store.prune(referenceDate: march)

        XCTAssertEqual(removed, ["2026-01"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "usage-2026-01.jsonl").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "usage-2026-02.jsonl").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRecordAndShardHardLimitsFailBeforeUnboundedGrowth() async throws {
        let recordDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: recordDirectory) }
        let recordStore = UsageLedgerStore(
            directoryURL: recordDirectory,
            limits: .init(maximumRecordBytes: 300, maximumShardBytes: 2_000)
        )
        var oversized = makeRecord(requestID: "oversized", date: january)
        oversized = UsageLedgerRecord(
            requestID: oversized.requestID,
            timestamp: oversized.timestamp,
            workspaceID: oversized.workspaceID,
            virtualKeyID: oversized.virtualKeyID,
            providerID: oversized.providerID,
            credentialID: oversized.credentialID,
            model: String(repeating: "x", count: 1_000),
            statusCode: oversized.statusCode,
            latencyMilliseconds: oversized.latencyMilliseconds,
            inputTokens: oversized.inputTokens,
            outputTokens: oversized.outputTokens,
            estimatedCostUSD: oversized.estimatedCostUSD
        )

        do {
            try await recordStore.append(oversized)
            XCTFail("oversized record should be rejected")
        } catch {
            XCTAssertEqual(error as? UsageLedgerError, .recordTooLarge(maximum: 300))
        }

        let shardDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: shardDirectory) }
        let initialStore = UsageLedgerStore(
            directoryURL: shardDirectory,
            limits: .init(maximumRecordBytes: 2_000, maximumShardBytes: 2_000)
        )
        try await initialStore.append(makeRecord(requestID: "first", date: january))
        let fileURL = shardDirectory.appending(path: "usage-2026-01.jsonl")
        let existingBytes = try XCTUnwrap(
            try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let maximumShardBytes = existingBytes + 8
        let constrainedStore = UsageLedgerStore(
            directoryURL: shardDirectory,
            limits: .init(
                maximumRecordBytes: 2_000,
                maximumShardBytes: maximumShardBytes
            )
        )
        do {
            try await constrainedStore.append(makeRecord(requestID: "second", date: january))
            XCTFail("full shard should reject another record")
        } catch {
            XCTAssertEqual(
                error as? UsageLedgerError,
                .shardTooLarge(month: "2026-01", maximum: maximumShardBytes)
            )
        }
    }

    func testCorruptedTrailingLineIsIgnoredButValidRecordsRemainQueryable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)
        try await store.append(makeRecord(requestID: "valid", date: january))
        let url = directory.appending(path: "usage-2026-01.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"requestID":"partial""#.utf8))
        try handle.close()

        let page = try await store.query(month: "2026-01", limit: 100)

        XCTAssertEqual(page.records.map(\.requestID), ["valid"])
        XCTAssertNil(page.nextCursor)
    }

    func testAppendRepairsAnInterruptedTrailingLineWithoutLosingPriorRows() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)
        try await store.append(makeRecord(requestID: "first", date: january))
        let url = directory.appending(path: "usage-2026-01.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"requestID":"partial""#.utf8))
        try handle.close()

        try await store.append(makeRecord(requestID: "second", date: january))
        let page = try await store.query(month: "2026-01", limit: 100)

        XCTAssertEqual(page.records.map(\.requestID), ["first", "second"])
    }

    func testChunkedQueryNearEndOfLargeShardHasBoundedLatencyAndRSS() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shard = directory.appending(path: "usage-2026-01.jsonl")
        let descriptor = Darwin.open(
            shard.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        let sparsePrefixBytes = 63 * 1_024 * 1_024
        XCTAssertEqual(Darwin.ftruncate(descriptor, off_t(sparsePrefixBytes)), 0)
        var newline: UInt8 = 0x0A
        XCTAssertEqual(
            Darwin.pwrite(descriptor, &newline, 1, off_t(sparsePrefixBytes - 1)),
            1
        )
        let record = try ledgerEncodedLine(makeRecord(requestID: "tail", date: january))
        let writeResult = record.withUnsafeBytes { bytes in
            Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, off_t(sparsePrefixBytes))
        }
        XCTAssertEqual(writeResult, record.count)

        let store = UsageLedgerStore(
            directoryURL: directory,
            limits: .init(maximumShardBytes: UsageLedgerLimits.hardMaximumShardBytes)
        )
        let cursor = UsageLedgerCursor(
            month: "2026-01",
            opaqueByteOffset: UInt64(sparsePrefixBytes),
            legacyLineOffset: 0
        )
        let rssBefore = residentMemoryBytes()
        XCTAssertGreaterThan(rssBefore, 0)
        let started = ContinuousClock.now

        let page = try await store.query(month: "2026-01", cursor: cursor, limit: 1)

        let elapsed = started.duration(to: .now)
        let rssAfter = residentMemoryBytes()
        XCTAssertEqual(page.records.map(\.requestID), ["tail"])
        XCTAssertNil(page.nextCursor)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertLessThan(
            rssAfter > rssBefore ? rssAfter - rssBefore : 0,
            16 * 1_024 * 1_024,
            "a tail page must not materialize the entire 63 MiB shard"
        )
    }

    func testInvalidMonthAndCrossMonthCursorFailClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageLedgerStore(directoryURL: directory)
        try await store.append(makeRecord(requestID: "valid", date: january))
        let first = try await store.query(month: "2026-01", limit: 1)

        do {
            _ = try await store.query(month: "../../private", limit: 1)
            XCTFail("path-like month should be rejected")
        } catch {
            XCTAssertEqual(error as? UsageLedgerError, .invalidMonth("../../private"))
        }

        do {
            _ = try await store.query(
                month: "2026-02",
                cursor: UsageLedgerCursor(month: "2026-01", lineOffset: 1),
                limit: 1
            )
            XCTFail("a cursor cannot cross monthly shards")
        } catch {
            XCTAssertEqual(error as? UsageLedgerError, .invalidCursor)
        }

        XCTAssertNil(first.nextCursor)
    }

    private func makeRecord(requestID: String, date: Date) -> UsageLedgerRecord {
        UsageLedgerRecord(
            requestID: requestID,
            timestamp: date,
            workspaceID: UUID(uuidString: "3FEF6F04-93D8-48AD-A3F4-DA41E7DE7790"),
            virtualKeyID: UUID(uuidString: "B1FBC97E-C1AE-4E09-9B28-D00733930973"),
            providerID: UUID(uuidString: "2D07165E-4261-4578-80D6-8555C44D7E30")!,
            credentialID: UUID(uuidString: "136D2C32-6222-49AA-91F8-24900AAB9E0C"),
            model: "model-a",
            statusCode: 200,
            latencyMilliseconds: 245,
            inputTokens: 12,
            outputTokens: 34,
            estimatedCostUSD: 0.0012
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ModelHubUsageLedgerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func permissionBits(at url: URL) throws -> mode_t {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return information.st_mode & mode_t(0o777)
    }

    private func ledgerEncodedLine(_ record: UsageLedgerRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private func residentMemoryBytes() -> UInt64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(information.resident_size) : 0
    }
}
