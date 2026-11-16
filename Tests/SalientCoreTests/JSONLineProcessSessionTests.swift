import Darwin
import Foundation
import XCTest

@testable import SalientCore

final class JSONLineProcessSessionTests: XCTestCase {
    func testFramesBufferedLinesAndDrainsLargeStderr() async throws {
        let session = makeSession(
            script: """
                import sys
                sys.stderr.write("e" * 2000000)
                sys.stderr.flush()
                print('{"event":"ready"}', flush=True)
                for line in sys.stdin:
                    print(line.strip(), flush=True)
                """)
        let ready = try await session.start()
        let payload = Data(#"{"id":"synthetic"}"#.utf8)
        let response = try await session.requestLine(payload)
        await session.stop()

        XCTAssertEqual(ready, Data(#"{"event":"ready"}"#.utf8))
        XCTAssertEqual(response, payload)
    }

    func testReturnsInvalidJSONLineForCallerValidationWithoutBlocking() async throws {
        let session = makeSession(
            script: """
                import sys
                print('{"event":"ready"}', flush=True)
                for line in sys.stdin:
                    print('not-json', flush=True)
                """)
        _ = try await session.start()
        let response = try await session.requestLine(Data("{}".utf8))
        await session.stop()

        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: response))
    }

    func testFailsPendingRequestWhenHelperDies() async throws {
        let session = makeSession(
            script: """
                import sys
                print('{"event":"ready"}', flush=True)
                sys.stdin.readline()
                sys.exit(7)
                """)
        _ = try await session.start()

        do {
            _ = try await session.requestLine(Data("{}".utf8))
            XCTFail("Expected helper death.")
        } catch let error as JSONLineProcessError {
            XCTAssertEqual(error, .processExited("JSON-line fixture"))
        }
    }

    func testTimesOutAndStopsDesynchronizedHelper() async throws {
        let session = makeSession(
            requestTimeoutSeconds: 0.1,
            script: """
                import sys, time
                print('{"event":"ready"}', flush=True)
                sys.stdin.readline()
                time.sleep(30)
                """
        )
        _ = try await session.start()

        do {
            _ = try await session.requestLine(Data("{}".utf8))
            XCTFail("Expected timeout.")
        } catch let error as JSONLineProcessError {
            XCTAssertEqual(error, .timedOut("JSON-line fixture"))
        }
        let isRunning = await session.isRunning()
        XCTAssertFalse(isRunning)
    }

    func testCancellationStopsPendingRequestPromptly() async throws {
        // The 30 s request timeout and 30 s helper sleep make any non-cancellation outcome
        // distinguishable by error type rather than by a tight wall-clock deadline.
        let session = makeSession(
            requestTimeoutSeconds: 30,
            script: """
                import json, os, sys, time
                print(json.dumps({"event": "ready", "pid": os.getpid()}), flush=True)
                sys.stdin.readline()
                sys.stderr.write("request-received\\n")
                sys.stderr.flush()
                time.sleep(30)
                """)
        let fixture = try fixtureProcess(fromReadyLine: try await session.start())
        let request = Task {
            try await session.requestLine(Data("{}".utf8))
        }
        let helperReceivedRequest = await waitUntil(within: .seconds(10)) {
            String(decoding: await session.retainedStderr(), as: UTF8.self).contains("request-received")
        }
        XCTAssertTrue(helperReceivedRequest, "Expected the helper to be blocked on a pending request before cancellation.")
        let clock = ContinuousClock()
        let cancelledAt = clock.now

        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected request cancellation.")
        } catch is CancellationError {
            XCTAssertLessThan(clock.now - cancelledAt, .seconds(10), "Cancellation must not wait for the 30 s request timeout.")
        } catch {
            XCTFail("Expected CancellationError, got \(error).")
        }
        let isRunningAfterCancellation = await session.isRunning()
        XCTAssertFalse(isRunningAfterCancellation)
        let helperGone = await waitUntilGone(fixture, within: .seconds(10))
        XCTAssertTrue(helperGone, "Expected cancellation to stop the helper process itself.")
    }

    func testStopEscalatesWhenHelperIgnoresSIGTERM() async throws {
        // The helper ignores SIGTERM and stdin EOF and would only exit by itself after 60 s,
        // so its disappearance well before then can only come from stop()'s SIGKILL escalation.
        let session = makeSession(script: sigtermIgnoringHelperScript)
        let fixture = try fixtureProcess(fromReadyLine: try await session.start())
        let clock = ContinuousClock()
        let stopStartedAt = clock.now

        await session.stop()

        XCTAssertLessThan(
            clock.now - stopStartedAt,
            .seconds(10),
            "stop() must stay bounded instead of waiting for the helper's own 60 s exit."
        )
        let isRunningAfterStop = await session.isRunning()
        XCTAssertFalse(isRunningAfterStop)
        let helperGone = await waitUntilGone(fixture, within: .seconds(10))
        XCTAssertTrue(helperGone, "Expected SIGKILL escalation to terminate the helper PID.")
    }

    func testStopFromCancelledCallerStillKillsHelperThatIgnoresSIGTERM() async throws {
        let session = makeSession(script: sigtermIgnoringHelperScript)
        let fixture = try fixtureProcess(fromReadyLine: try await session.start())

        let stopTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await session.stop()
        }
        await stopTask.value

        let isRunningAfterStop = await session.isRunning()
        XCTAssertFalse(isRunningAfterStop)
        let helperGone = await waitUntilGone(fixture, within: .seconds(10))
        XCTAssertTrue(helperGone, "A cancelled caller must skip the grace period, not the SIGKILL escalation.")
    }

    func testExitPollingHonorsDeadlineWhenSleepsOvershoot() async {
        // Every requested 10 ms sleep advances the simulated clock by 200 ms, as on a starved
        // scheduler. A 500 ms budget must end after 3 sleeps, not after a fixed 50 iterations.
        let clock = OvershootingClock(advancingEachSleepBy: .milliseconds(200))

        let finished = await JSONLineProcessSession.pollUntil(
            { false },
            within: .milliseconds(500),
            pollingEvery: .milliseconds(10),
            clock: clock
        )

        XCTAssertFalse(finished)
        XCTAssertEqual(clock.sleepCount, 3)
        XCTAssertEqual(clock.now.offset, .milliseconds(600))
    }

    func testExitPollingReturnsAsSoonAsConditionHolds() async {
        let clock = OvershootingClock(advancingEachSleepBy: .milliseconds(10))

        let finished = await JSONLineProcessSession.pollUntil(
            { clock.sleepCount >= 2 },
            within: .milliseconds(500),
            pollingEvery: .milliseconds(10),
            clock: clock
        )

        XCTAssertTrue(finished)
        XCTAssertEqual(clock.sleepCount, 2)
    }

    func testExitPollingDoesNotSleepForCancelledCaller() async {
        let clock = OvershootingClock(advancingEachSleepBy: .milliseconds(10))

        let finished = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await JSONLineProcessSession.pollUntil(
                { false },
                within: .milliseconds(500),
                pollingEvery: .milliseconds(10),
                clock: clock
            )
        }.value

        XCTAssertFalse(finished)
        XCTAssertEqual(clock.sleepCount, 0)
    }

    func testStreamingRequestPreservesBurstLineOrder() async throws {
        let session = makeSession(
            script: """
                import json, sys
                print('{"event":"ready"}', flush=True)
                for _ in sys.stdin:
                    for index in range(100):
                        print(json.dumps({"index": index}), flush=True)
                """)
        _ = try await session.start()
        let collector = OrderedLineCollector()

        try await session.request(Data("{}".utf8)) { line in
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Int]
            let index = try XCTUnwrap(object?["index"])
            await collector.append(index)
            return index == 99 ? .finish : .continueReading
        }
        await session.stop()

        let values = await collector.values
        XCTAssertEqual(values, Array(0..<100))
    }

    private func makeSession(
        requestTimeoutSeconds: TimeInterval = 2,
        script: String
    ) -> JSONLineProcessSession {
        JSONLineProcessSession(
            configuration: JSONLineProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script],
                startupTimeoutSeconds: 2,
                requestTimeoutSeconds: requestTimeoutSeconds,
                maximumLineBytes: 1_024,
                maximumRetainedStderrBytes: 4_096,
                redactedDescription: "JSON-line fixture"
            ))
    }

    private let sigtermIgnoringHelperScript = """
        import json, os, signal, time
        signal.signal(signal.SIGTERM, lambda *_: None)
        print(json.dumps({"event": "ready", "pid": os.getpid()}), flush=True)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            time.sleep(0.05)
        """

    /// Identifies the helper by PID plus kernel start time and kills it at teardown if a failing
    /// test left it running, without risking a reused PID.
    private func fixtureProcess(fromReadyLine readyLine: Data?) throws -> FixtureProcess {
        let ready = try XCTUnwrap(readyLine)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: ready) as? [String: Any])
        let processID = try XCTUnwrap((payload["pid"] as? NSNumber)?.int32Value)
        let fixture = try XCTUnwrap(
            FixtureProcess(processID: processID),
            "Helper exited before it could be identified."
        )
        addTeardownBlock {
            if fixture.isAlive {
                kill(fixture.processID, SIGKILL)
            }
        }
        return fixture
    }

    private func waitUntilGone(_ fixture: FixtureProcess, within timeout: Duration) async -> Bool {
        await waitUntil(within: timeout) { !fixture.isAlive }
    }

    private func waitUntil(within timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private struct FixtureProcess: Sendable {
    let processID: pid_t
    private let startSeconds: Int
    private let startMicroseconds: Int32

    init?(processID: pid_t) {
        guard let startTime = Self.startTime(of: processID) else { return nil }
        self.processID = processID
        startSeconds = startTime.seconds
        startMicroseconds = startTime.microseconds
    }

    /// True while the same process (including an unreaped zombie) still occupies the PID.
    var isAlive: Bool {
        guard let startTime = Self.startTime(of: processID) else { return false }
        return startTime.seconds == startSeconds && startTime.microseconds == startMicroseconds
    }

    private static func startTime(of processID: pid_t) -> (seconds: Int, microseconds: Int32)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        let mibCount = u_int(mib.count)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, mibCount, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let startTime = info.kp_proc.p_starttime
        return (Int(startTime.tv_sec), Int32(startTime.tv_usec))
    }
}

/// Simulated monotonic clock whose sleeps always advance time by a fixed overshoot.
/// Only used from one task at a time, hence `@unchecked Sendable`.
private final class OvershootingClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private let overshoot: Swift.Duration
    private(set) var now = Instant(offset: .zero)
    private(set) var sleepCount = 0

    var minimumResolution: Swift.Duration { .zero }

    init(advancingEachSleepBy overshoot: Swift.Duration) {
        self.overshoot = overshoot
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        sleepCount += 1
        now = now.advanced(by: overshoot)
    }
}

private actor OrderedLineCollector {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
