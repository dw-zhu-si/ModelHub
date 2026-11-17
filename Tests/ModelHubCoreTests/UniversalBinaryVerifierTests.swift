import Foundation
import XCTest

final class UniversalBinaryVerifierTests: XCTestCase {
    func testVerifierChecksArm64AndX8664Separately() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("modelhub-universal-verifier-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let source = temporaryDirectory.appendingPathComponent("fixture.c")
        let arm64Object = temporaryDirectory.appendingPathComponent("fixture-arm64.o")
        let x86Object = temporaryDirectory.appendingPathComponent("fixture-x86_64.o")
        let universalObject = temporaryDirectory.appendingPathComponent("fixture-universal.o")
        try "int modelhub_fixture(void) { return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)

        for (architecture, output) in [("arm64", arm64Object), ("x86_64", x86Object)] {
            let compile = try runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["clang", "-arch", architecture, "-c", source.path, "-o", output.path]
            )
            XCTAssertEqual(compile.status, 0, compile.standardError)
        }
        let merge = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-create", arm64Object.path, x86Object.path, "-output", universalObject.path]
        )
        XCTAssertEqual(merge.status, 0, merge.standardError)

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [verifierScript.path, universalObject.path]
        )

        XCTAssertEqual(result.status, 0, result.standardError)
    }

    func testAppStorePackagingVerifiesEveryBundledExecutableWithoutCombinedArguments() throws {
        let script = try String(contentsOf: appStorePackagingScript, encoding: .utf8)

        XCTAssertFalse(script.contains("-verify_arch arm64 x86_64"))
        XCTAssertTrue(script.contains("\"${CANDIDATE_APP}/Contents/MacOS/ModelHub\""))
        XCTAssertTrue(script.contains("\"${CANDIDATE_APP}/Contents/MacOS/ModelHubACP\""))
        XCTAssertTrue(
            script.contains(
                "\"${CANDIDATE_APP}/Contents/PlugIns/ModelHubWidget.appex/Contents/MacOS/ModelHubWidget\""
            )
        )
        XCTAssertTrue(
            script.contains("/bin/zsh \"${SCRIPT_DIR}/verify_universal_binary.sh\" \"${binary}\"")
        )
    }

    private var verifierScript: URL {
        projectRoot.appendingPathComponent("scripts/verify_universal_binary.sh")
    }

    private var appStorePackagingScript: URL {
        projectRoot.appendingPathComponent("scripts/package_app_store_candidate.sh")
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runProcess(
        executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, standardError: String) {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let data = standardError.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
