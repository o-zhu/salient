import Foundation
import XCTest

@testable import SalientCore

final class AsyncProcessRunnerTests: XCTestCase {
    func testStreamsLargeStandardInputWithoutBlockingOutput() async throws {
        let data = Data(repeating: 65, count: 2_000_000)
        let result = try await AsyncProcessRunner().run(AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            standardInput: data,
            timeoutSeconds: 10,
            maximumRetainedOutputBytes: data.count,
            redactedDescription: "stdin fixture"
        ))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, data)
    }
    func testDrainsStdoutAndStderrLargerThanPipeCapacityWithoutDeadlock() async throws {
        let byteCount = 2_000_000
        let retainedLimit = 128_000
        let result = try await AsyncProcessRunner().run(
            AsyncProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [
                    "-c",
                    "import sys; sys.stdout.write('o' * \(byteCount)); sys.stderr.write('e' * \(byteCount))",
                ],
                timeoutSeconds: 10,
                maximumRetainedOutputBytes: retainedLimit,
                redactedDescription: "large-output fixture"
            ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, retainedLimit)
        XCTAssertEqual(result.stderr.count, retainedLimit)
        XCTAssertEqual(Set(result.stdout), Set([Character("o").asciiValue!]))
        XCTAssertEqual(Set(result.stderr), Set([Character("e").asciiValue!]))
    }

    func testTerminatesProcessAtTimeout() async throws {
        do {
            _ = try await AsyncProcessRunner().run(
                AsyncProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-c", "import time; time.sleep(30)"],
                    timeoutSeconds: 0.1,
                    redactedDescription: "timeout fixture"
                ))
            XCTFail("Expected timeout.")
        } catch let error as AsyncProcessError {
            XCTAssertEqual(error, .timedOut("timeout fixture"))
        }
    }

    func testCancellationTerminatesProcess() async throws {
        let task = Task {
            try await AsyncProcessRunner().run(
                AsyncProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-c", "import time; time.sleep(30)"],
                    timeoutSeconds: 60,
                    redactedDescription: "cancellation fixture"
                ))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
        }
    }
}
