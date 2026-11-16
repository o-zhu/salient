import Darwin
import Foundation

public struct AsyncProcessRequest: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var standardInput: Data?
    public var environment: [String: String]
    public var currentDirectoryURL: URL?
    public var timeoutSeconds: TimeInterval?
    public var maximumRetainedOutputBytes: Int
    public var redactedDescription: String

    public init(
        executableURL: URL,
        arguments: [String] = [],
        standardInput: Data? = nil,
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        timeoutSeconds: TimeInterval? = 600,
        maximumRetainedOutputBytes: Int = 1_048_576,
        redactedDescription: String
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeoutSeconds = timeoutSeconds
        self.maximumRetainedOutputBytes = max(0, maximumRetainedOutputBytes)
        self.redactedDescription = redactedDescription
    }
}

public struct AsyncProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum AsyncProcessError: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let description):
            "Could not start \(description)."
        case .timedOut(let description):
            "\(description) timed out."
        }
    }
}

public protocol AsyncProcessRunning: Sendable {
    func run(_ request: AsyncProcessRequest) async throws -> AsyncProcessResult
}

public struct AsyncProcessRunner: AsyncProcessRunning {
    public init() {}

    public func run(_ request: AsyncProcessRequest) async throws -> AsyncProcessResult {
        let lifecycle = AsyncProcessLifecycle()
        return try await withTaskCancellationHandler {
            guard let timeoutSeconds = request.timeoutSeconds, timeoutSeconds > 0 else {
                return try await lifecycle.run(request)
            }
            return try await withThrowingTaskGroup(of: AsyncProcessResult.self) { group in
                group.addTask {
                    try await lifecycle.run(request)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    await lifecycle.terminate()
                    throw AsyncProcessError.timedOut(request.redactedDescription)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
        } onCancel: {
            Task {
                await lifecycle.terminate()
            }
        }
    }
}

private actor AsyncProcessLifecycle {
    private var process: Process?

    func run(_ request: AsyncProcessRequest) async throws -> AsyncProcessResult {
        try Task.checkCancellation()

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = request.standardInput == nil ? nil : Pipe()
        let termination = ProcessTerminationSignal()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin ?? FileHandle.nullDevice
        if !request.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, new in new }
        }
        process.terminationHandler = { terminatedProcess in
            Task {
                await termination.finish(status: terminatedProcess.terminationStatus)
            }
        }
        self.process = process

        do {
            try process.run()
        } catch {
            self.process = nil
            process.terminationHandler = nil
            throw AsyncProcessError.launchFailed(request.redactedDescription)
        }

        let outputLimit = request.maximumRetainedOutputBytes
        let stdoutTask = Task.detached(priority: .utility) {
            try Self.drain(stdout.fileHandleForReading, retainingAtMost: outputLimit)
        }
        let stderrTask = Task.detached(priority: .utility) {
            try Self.drain(stderr.fileHandleForReading, retainingAtMost: outputLimit)
        }
        let stdinTask = Task.detached(priority: .utility) {
            guard let stdin, let data = request.standardInput else { return }
            defer { try? stdin.fileHandleForWriting.close() }
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }

        let status = await termination.wait()
        // A cancelled child may close stdin early; cancellation wins over that write error.
        _ = await stdinTask.result
        let stdoutData = try await stdoutTask.value
        let stderrData = try await stderrTask.value
        self.process = nil
        process.terminationHandler = nil
        try Task.checkCancellation()
        return AsyncProcessResult(exitCode: status, stdout: stdoutData, stderr: stderrData)
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            if kill(processIdentifier, 0) == 0 {
                kill(processIdentifier, SIGKILL)
            }
        }
    }

    nonisolated private static func drain(
        _ handle: FileHandle,
        retainingAtMost limit: Int
    ) throws -> Data {
        var retained = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            guard limit > 0 else { continue }
            if chunk.count >= limit {
                retained = Data(chunk.suffix(limit))
                continue
            }
            let overflow = retained.count + chunk.count - limit
            if overflow > 0 {
                retained.removeFirst(overflow)
            }
            retained.append(chunk)
        }
        return retained
    }
}

private actor ProcessTerminationSignal {
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        if let status {
            return status
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish(status: Int32) {
        guard self.status == nil else { return }
        self.status = status
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }
}
