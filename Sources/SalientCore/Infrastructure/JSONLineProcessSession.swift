import Darwin
import Foundation

public struct JSONLineProcessConfiguration: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectoryURL: URL?
    public var startupTimeoutSeconds: TimeInterval
    public var requestTimeoutSeconds: TimeInterval
    public var maximumLineBytes: Int
    public var maximumRetainedStderrBytes: Int
    public var redactedDescription: String

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        startupTimeoutSeconds: TimeInterval = 120,
        requestTimeoutSeconds: TimeInterval = 600,
        maximumLineBytes: Int = 67_108_864,
        maximumRetainedStderrBytes: Int = 262_144,
        redactedDescription: String
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumRetainedStderrBytes = max(0, maximumRetainedStderrBytes)
        self.redactedDescription = redactedDescription
    }
}

public enum JSONLineProcessError: LocalizedError, Equatable, Sendable {
    case alreadyHandlingRequest(String)
    case launchFailed(String)
    case processExited(String)
    case timedOut(String)
    case lineTooLong(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyHandlingRequest(let description):
            "\(description) is already handling a request."
        case .launchFailed(let description):
            "Could not start \(description)."
        case .processExited(let description):
            "\(description) exited before responding."
        case .timedOut(let description):
            "\(description) timed out."
        case .lineTooLong(let description):
            "\(description) returned an oversized response."
        case .writeFailed(let description):
            "\(description) stopped while accepting a request."
        }
    }
}

public enum JSONLineResponseDisposition: Sendable {
    case continueReading
    case finish
}

public actor JSONLineProcessSession {
    private let configuration: JSONLineProcessConfiguration
    private var process: Process?
    private var input: FileHandle?
    private var reader: BufferedLineReader?
    private var stderrCollector: BoundedOutputCollector?
    private var requestInFlight = false

    public init(configuration: JSONLineProcessConfiguration) {
        self.configuration = configuration
    }

    public func isRunning() -> Bool {
        process?.isRunning == true
    }

    @discardableResult
    public func start(expectingReadyLine: Bool = true) async throws -> Data? {
        if process?.isRunning == true {
            return nil
        }
        await stop()

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let reader = BufferedLineReader(maximumLineBytes: configuration.maximumLineBytes)
        let stderrCollector = BoundedOutputCollector(limit: configuration.maximumRetainedStderrBytes)
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        if !configuration.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        }

        do {
            try process.run()
        } catch {
            throw JSONLineProcessError.launchFailed(configuration.redactedDescription)
        }

        self.process = process
        input = stdin.fileHandleForWriting
        self.reader = reader
        self.stderrCollector = stderrCollector
        await reader.start(reading: stdout.fileHandleForReading)
        await stderrCollector.start(reading: stderr.fileHandleForReading)

        guard expectingReadyLine else { return nil }
        do {
            return try await nextLine(timeoutSeconds: configuration.startupTimeoutSeconds)
        } catch {
            await stop()
            throw error
        }
    }

    public func requestLine(_ payload: Data, timeoutSeconds: TimeInterval? = nil) async throws -> Data {
        try beginRequest()
        defer { requestInFlight = false }
        do {
            try await writeLine(payload)
            return try await nextLine(timeoutSeconds: timeoutSeconds ?? configuration.requestTimeoutSeconds)
        } catch {
            await stop()
            throw error
        }
    }

    public func request(
        _ payload: Data,
        timeoutSeconds: TimeInterval? = nil,
        onLine: @Sendable (Data) async throws -> JSONLineResponseDisposition
    ) async throws {
        try beginRequest()
        defer { requestInFlight = false }
        do {
            try await writeLine(payload)
            while true {
                let line = try await nextLine(timeoutSeconds: timeoutSeconds ?? configuration.requestTimeoutSeconds)
                if try await onLine(line) == .finish {
                    return
                }
            }
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        requestInFlight = false
        try? input?.close()
        input = nil
        await reader?.stop()
        reader = nil
        await stderrCollector?.stop()
        stderrCollector = nil
        guard let process else { return }
        self.process = nil
        guard process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()

        if await waitForExit(of: process, within: Self.terminationGracePeriod) {
            return
        }
        // Process reaps its own child, so only signal the PID while it still reports running;
        // once it has observed the exit the PID may be reused.
        guard process.isRunning else { return }
        kill(processIdentifier, SIGKILL)
        _ = await waitForExit(of: process, within: Self.killReapPeriod)
    }

    private static let terminationGracePeriod: Duration = .milliseconds(500)
    private static let killReapPeriod: Duration = .milliseconds(500)
    private static let exitPollInterval: Duration = .milliseconds(10)

    private func waitForExit(of process: Process, within period: Duration) async -> Bool {
        await Self.pollUntil(
            { !process.isRunning },
            within: period,
            pollingEvery: Self.exitPollInterval,
            clock: ContinuousClock()
        )
    }

    /// Polls against a monotonic deadline so slow individual sleeps cannot stretch the total wait.
    /// Returns false without sleeping once the caller is cancelled, so `stop()` escalates at once.
    static func pollUntil<C: Clock>(
        _ isDone: () -> Bool,
        within period: C.Duration,
        pollingEvery interval: C.Duration,
        clock: C,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        let deadline = clock.now.advanced(by: period)
        while !isDone() {
            let now = clock.now
            guard !Task.isCancelled, now < deadline else { return false }
            try? await clock.sleep(until: min(now.advanced(by: interval), deadline), tolerance: nil)
        }
        return true
    }

    public func retainedStderr() async -> Data {
        await stderrCollector?.data() ?? Data()
    }

    private func beginRequest() throws {
        guard !requestInFlight else {
            throw JSONLineProcessError.alreadyHandlingRequest(configuration.redactedDescription)
        }
        guard process?.isRunning == true, input != nil, reader != nil else {
            throw JSONLineProcessError.processExited(configuration.redactedDescription)
        }
        requestInFlight = true
    }

    private func writeLine(_ payload: Data) async throws {
        guard let input, process?.isRunning == true else {
            throw JSONLineProcessError.processExited(configuration.redactedDescription)
        }
        var framedPayload = payload
        framedPayload.append(0x0A)
        do {
            try input.write(contentsOf: framedPayload)
        } catch {
            await stop()
            throw JSONLineProcessError.writeFailed(configuration.redactedDescription)
        }
    }

    private func nextLine(timeoutSeconds: TimeInterval) async throws -> Data {
        guard let reader else {
            throw JSONLineProcessError.processExited(configuration.redactedDescription)
        }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do {
                    return try await reader.nextLine()
                } catch is CancellationError {
                    throw CancellationError()
                } catch BufferedLineReaderError.lineTooLong {
                    throw JSONLineProcessError.lineTooLong(self.configuration.redactedDescription)
                } catch {
                    throw JSONLineProcessError.processExited(self.configuration.redactedDescription)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw JSONLineProcessError.timedOut(self.configuration.redactedDescription)
            }
            defer { group.cancelAll() }
            guard let line = try await group.next() else {
                throw CancellationError()
            }
            return line
        }
    }
}

private enum BufferedLineReaderError: Error {
    case endOfFile
    case lineTooLong
}

private actor BufferedLineReader {
    private let maximumLineBytes: Int
    private var buffer = Data()
    private var lines: [Data] = []
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var terminalError: BufferedLineReaderError?
    private var handle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var readContinuation: AsyncStream<Data>.Continuation?

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    func start(reading handle: FileHandle) {
        self.handle = handle
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        readContinuation = continuation
        readTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                if chunk.isEmpty {
                    await self.finish(.endOfFile)
                    return
                }
                await self.ingest(chunk)
            }
        }
        handle.readabilityHandler = { readableHandle in
            continuation.yield(readableHandle.availableData)
        }
    }

    func nextLine() async throws -> Data {
        try Task.checkCancellation()
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !lines.isEmpty {
                    continuation.resume(returning: lines.removeFirst())
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    waiterOrder.append(waiterID)
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func stop() {
        handle?.readabilityHandler = nil
        readContinuation?.finish()
        readContinuation = nil
        readTask?.cancel()
        readTask = nil
        try? handle?.close()
        handle = nil
        finish(.endOfFile)
    }

    private func ingest(_ chunk: Data) {
        guard terminalError == nil else { return }
        buffer.append(chunk)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            guard line.count <= maximumLineBytes else {
                finish(.lineTooLong)
                return
            }
            deliver(line)
        }
        if buffer.count > maximumLineBytes {
            finish(.lineTooLong)
        }
    }

    private func finish(_ error: BufferedLineReaderError) {
        guard terminalError == nil else { return }
        terminalError = error
        buffer.removeAll(keepingCapacity: false)
        let waiting = Array(waiters.values)
        waiters.removeAll()
        waiterOrder.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
    }

    private func deliver(_ line: Data) {
        while let waiterID = waiterOrder.first {
            waiterOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: waiterID) else {
                continue
            }
            continuation.resume(returning: line)
            return
        }
        lines.append(line)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        waiterOrder.removeAll { $0 == waiterID }
        continuation.resume(throwing: CancellationError())
    }
}

private actor BoundedOutputCollector {
    private let limit: Int
    private var retained = Data()
    private var handle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var readContinuation: AsyncStream<Data>.Continuation?

    init(limit: Int) {
        self.limit = limit
    }

    func start(reading handle: FileHandle) {
        self.handle = handle
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        readContinuation = continuation
        readTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                if !chunk.isEmpty {
                    await self.append(chunk)
                }
            }
        }
        handle.readabilityHandler = { readableHandle in
            continuation.yield(readableHandle.availableData)
        }
    }

    func data() -> Data {
        retained
    }

    func stop() {
        handle?.readabilityHandler = nil
        readContinuation?.finish()
        readContinuation = nil
        readTask?.cancel()
        readTask = nil
        try? handle?.close()
        handle = nil
    }

    private func append(_ chunk: Data) {
        guard limit > 0 else { return }
        if chunk.count >= limit {
            retained = Data(chunk.suffix(limit))
            return
        }
        let overflow = retained.count + chunk.count - limit
        if overflow > 0 {
            retained.removeFirst(overflow)
        }
        retained.append(chunk)
    }
}
