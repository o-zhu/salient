import Foundation

public enum PocketRuntimeError: LocalizedError, Equatable, Sendable {
    case needsSetup, busy, invalidAudio, insufficientSpace, setupFailed(String)
    public var errorDescription: String? {
        switch self {
        case .needsSetup: "Download Pocket in Narration settings first."
        case .busy: "Pocket is busy in another running copy of Salient. Please try again shortly."
        case .insufficientSpace: "Pocket needs about 550 MB of free space to download and verify its voice. Free some space and retry."
        case .invalidAudio: "Pocket could not complete this narration. Try again or choose Native Apple."
        case .setupFailed(let stage): "Pocket setup could not complete \(stage). Check your connection and retry Download Pocket."
        }
    }
}

public struct PocketInstallProgress: Equatable, Sendable {
    public let stage: String
    public let fraction: Double
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?
    public init(stage: String, fraction: Double, downloadedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.stage = stage; self.fraction = fraction
        self.downloadedBytes = downloadedBytes; self.totalBytes = totalBytes
    }
}

public protocol PocketSynthesizing: Sendable {
    func isInstalled() async -> Bool
    func stream(text: String, requestID: UUID) async throws -> AsyncThrowingStream<QwenStreamingAudioChunk, Error>
    func cancel(requestID: UUID) async
}

/// A separate managed CPU worker. Installation is the only network-enabled path.
/// It deliberately shares neither the Qwen environment nor a Hugging Face login.
public actor PocketRuntimeManager: PocketSynthesizing {
    /// The writable managed destination. Downloads and repairs write only here.
    public nonisolated let root: URL
    /// Read-only stock assets signed into a packaged edition. Never written.
    public nonisolated let bundledRoot: URL?
    public nonisolated let workerURL: URL
    public static let version = "4.0.1"
    private let manifestOverride: PocketAssetManifest?
    private var session: JSONLineProcessSession?
    private var startupTask: Task<JSONLineProcessSession, Error>?
    private var startupID: UUID?
    private var activeTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var installing = false

    /// The default instance also accepts the app's bundled stock assets. An
    /// explicit `root` (probes, staging) stays isolated unless `bundledRoot` opts in.
    public init(root: URL? = nil, workerURL: URL? = nil, bundledRoot: URL? = nil) {
        self.init(root: root, workerURL: workerURL, bundledRoot: bundledRoot, manifest: nil)
    }

    /// Tests inject a synthetic manifest; production always uses the bundled one.
    init(root: URL?, workerURL: URL?, bundledRoot: URL?, manifest: PocketAssetManifest?) {
        self.root = root ?? Self.defaultRoot
        self.workerURL = workerURL ?? Self.bundledWorkerURL
        self.bundledRoot = bundledRoot ?? (root == nil ? Self.bundledAssetRoot : nil)
        self.manifestOverride = manifest
    }

    public nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Salient/PocketTTS/native-v2", isDirectory: true)
    }

    /// Stock English/Alba assets packaged in Contents/Resources/PocketTTS, so a
    /// fresh install reads offline without copying, unpacking or downloading.
    public nonisolated static var bundledAssetRoot: URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PocketTTS", isDirectory: true)
    }

    public nonisolated static var bundledWorkerURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/salient-pocket-worker")
        }
        // SwiftPM probes/tests find the helper beside their resource bundle.
        // Packaged apps use only their signed, embedded helper above.
        return Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("salient-pocket-worker")
    }

    public func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: workerURL.path) && resolvedAssetRoot() != nil
    }

    /// A complete managed install (download or repair) wins over the bundle.
    /// Receipt and sizes are checked here; the worker verifies hashes at launch.
    public func resolvedAssetRoot() -> URL? {
        guard let manifest = try? assetManifest() else { return nil }
        return [root, bundledRoot].compactMap { $0 }.first { manifest.hasCompleteReceipt(at: $0) }
    }

    private func assetManifest() throws -> PocketAssetManifest {
        try manifestOverride ?? PocketAssetManifest.bundled()
    }

    public func hasLegacyInstallation() -> Bool {
        guard root == Self.defaultRoot else { return false }
        return FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("receipt.json").path)
    }

    /// Reversible cleanup of the old app-managed stock runtime, after migration.
    /// Never touches Qwen, shared caches, custom voices, or arbitrary probe roots.
    public func removeLegacyInstallation() throws -> Bool {
        guard isInstalled(), root == Self.defaultRoot,
              let data = try? Data(contentsOf: legacyRoot.appendingPathComponent("receipt.json")),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["schema"] as? Int == 1, receipt["pocket_tts"] as? String == "3.1.0",
              receipt["voice"] as? String == "alba" else { return false }
        // The app created only these paths. Leave an installation containing
        // added/custom material for the owner to inspect instead of moving it.
        let manager = FileManager.default
        let allowed = Set(["assets", "installer", "python", "venv", "receipt.json", "NOTICES.md", "english-local.yaml", ".DS_Store"])
        let names = try manager.contentsOfDirectory(atPath: legacyRoot.path)
        let assets = try manager.contentsOfDirectory(atPath: legacyRoot.appendingPathComponent("assets").path)
        guard Set(names).isSubset(of: allowed),
              Set(assets).isSubset(of: ["model.safetensors", "tokenizer.model", "alba.safetensors", ".DS_Store"]),
              try legacyRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return false }
        try FileManager.default.trashItem(at: legacyRoot, resultingItemURL: nil)
        return true
    }

    private var legacyRoot: URL { root.deletingLastPathComponent().appendingPathComponent("runtime-v1") }

    public func isResident() async -> Bool { await session?.isRunning() == true }

    public func install(progress: @escaping @Sendable (PocketInstallProgress) async -> Void) async throws {
        guard !installing, activeRequestID == nil else { throw PocketRuntimeError.busy }
        installing = true
        defer { installing = false }
        await unload()
        let manager = FileManager.default
        let parent = root.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try PocketInstallLock(at: parent.appendingPathComponent(root.lastPathComponent + ".install.lock"))
        defer { withExtendedLifetime(lock) {} }
        guard manager.isExecutableFile(atPath: workerURL.path) else {
            throw PocketRuntimeError.setupFailed("the bundled speech engine; reinstall Salient")
        }
        await progress(.init(stage: "Preparing Pocket \(Self.version)", fraction: 0.02))
        let staging = parent.appendingPathComponent(root.lastPathComponent + ".staging", isDirectory: true)
        let manifest = try assetManifest()
        // Hash-verified bundled assets make repair a local copy into the managed
        // root; the bundle itself is only read.
        try await PocketAssetInstaller(manifest: manifest).prepare(at: staging, reusing: resolvedAssetRoot() ?? root, progress: progress)
        await progress(.init(stage: "Checking the voice offline", fraction: 0.9))
        // Staging is validated alone; it never borrows active or bundled assets.
        let candidate = PocketRuntimeManager(root: staging, workerURL: workerURL, bundledRoot: nil, manifest: manifest)
        do {
            let chunks = try await candidate.stream(text: "Pocket is ready to read.", requestID: UUID())
            var frames = 0
            var finished = false
            for try await chunk in chunks {
                try Task.checkCancellation()
                frames += chunk.audioData.count / 4
                finished = finished || chunk.isFinal
            }
            guard finished, frames > 2400 else { throw PocketRuntimeError.invalidAudio }
            await candidate.unload()
        } catch {
            await candidate.unload()
            throw error
        }
        try Task.checkCancellation()
        try Data(contentsOf: resource("Pocket-Notices", "md")).write(to: staging.appendingPathComponent("NOTICES.md"), options: .atomic)
        try PocketAssetInstaller.activate(staging: staging, destination: root)
        guard manifest.hasCompleteReceipt(at: root) else { throw PocketRuntimeError.setupFailed("the installation check") }
        await progress(.init(stage: "Pocket \(Self.version) is ready", fraction: 1))
    }

    public func warm() async throws { _ = try await residentSession() }

    public func stream(text: String, requestID: UUID) async throws -> AsyncThrowingStream<QwenStreamingAudioChunk, Error> {
        guard !installing, activeRequestID == nil else { throw PocketRuntimeError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4000 else {
            throw PocketRuntimeError.invalidAudio
        }
        activeRequestID = requestID
        do {
            let worker = try await residentSession()
            try Task.checkCancellation()
            guard activeRequestID == requestID else { throw CancellationError() }
            let payload = try JSONEncoder().encode(Request(id: requestID.uuidString, text: text))
            let pair = PocketAudioStream.makeStream()
            pair.continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { Task { await self?.cancel(requestID: requestID) } }
            }
            activeTask = Task { [weak self] in
                let decoder = PocketResponseDecoder(requestID: requestID.uuidString)
                do {
                    try await worker.request(payload, timeoutSeconds: 30) { line in
                        let chunk = try await decoder.consume(line)
                        try await PocketAudioStream.send(chunk, to: pair.continuation)
                        return chunk.isFinal ? .finish : .continueReading
                    }
                    await self?.finished(requestID)
                    pair.continuation.finish()
                } catch {
                    await self?.cancel(requestID: requestID)
                    pair.continuation.finish(throwing: error)
                }
            }
            return pair.stream
        } catch {
            await cancel(requestID: requestID)
            throw error
        }
    }

    public func cancel(requestID: UUID) async {
        guard activeRequestID == requestID else { return }
        await unload()
    }

    public func unload() async {
        activeRequestID = nil
        activeTask?.cancel()
        activeTask = nil
        startupID = nil
        startupTask?.cancel()
        startupTask = nil
        let old = session
        session = nil
        await old?.stop()
    }

    private func finished(_ id: UUID) {
        guard activeRequestID == id else { return }
        activeRequestID = nil
        activeTask = nil
    }

    private func residentSession() async throws -> JSONLineProcessSession {
        guard FileManager.default.isExecutableFile(atPath: workerURL.path),
              let assetRoot = resolvedAssetRoot() else { throw PocketRuntimeError.needsSetup }
        if let startupTask {
            let id = startupID
            do {
                let worker = try await startupTask.value
                guard startupID == id else { throw CancellationError() }
                return worker
            } catch {
                if startupID != id || Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        if let session, await session.isRunning() { return session }
        let worker = JSONLineProcessSession(configuration: .init(
            executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", "(version 1) (allow default) (deny network*)", workerURL.path, "--root", assetRoot.path, "--int8"],
            environment: environment, startupTimeoutSeconds: 90, requestTimeoutSeconds: 30,
            maximumLineBytes: 32768, maximumRetainedStderrBytes: 0,
            redactedDescription: "local Pocket speech"
        ))
        session = worker
        let id = UUID()
        startupID = id
        let task = Task {
            guard let line = try await worker.start(),
                  let ready = try? JSONDecoder().decode(Ready.self, from: line),
                  ready.type == "ready", ready.schema == 2, ready.version == Self.version else {
                await worker.stop()
                throw PocketRuntimeError.invalidAudio
            }
            return worker
        }
        startupTask = task
        do {
            let result = try await task.value
            guard startupID == id else { throw CancellationError() }
            startupTask = nil
            return result
        } catch {
            let wasCancelled = startupID != id || Task.isCancelled
            if startupID == id {
                startupTask = nil
                session = nil
            }
            await worker.stop()
            if wasCancelled { throw CancellationError() }
            throw error
        }
    }

    private var environment: [String: String] {
        // A bounded worker pool leaves headroom for browser/UI/playback work.
        // Compile-time M1 NEON kernels and Accelerate work across Apple Silicon.
        ["RAYON_NUM_THREADS": "4", "VECLIB_MAXIMUM_THREADS": "1", "TOKENIZERS_PARALLELISM": "false",
         "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1"]
    }

    private func resource(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw PocketRuntimeError.setupFailed("the app resources")
        }
        return url
    }

    private struct Ready: Decodable { let type: String; let schema: Int; let version: String }
    private struct Request: Encodable { let id: String; let text: String }
}

/// Validate framing before any PCM reaches the shared audio player.
actor PocketResponseDecoder {
    private let requestID: String
    private var nextSequence = 0
    private var totalFrames = 0
    init(requestID: String) { self.requestID = requestID }

    func consume(_ data: Data) throws -> QwenStreamingAudioChunk {
        let event = try JSONDecoder().decode(Event.self, from: data)
        guard event.id == requestID, event.sequence == nextSequence else { throw PocketRuntimeError.invalidAudio }
        let final = event.type == "done"
        let pcm: Data
        if final {
            guard totalFrames > 0, event.frames == totalFrames else { throw PocketRuntimeError.invalidAudio }
            pcm = Data()
        } else {
            guard event.type == "chunk", let encoded = event.pcm, let decoded = Data(base64Encoded: encoded),
                  event.frames > 0, event.frames <= 1920, decoded.count == event.frames * 4,
                  decoded.withUnsafeBytes({ bytes in
                      stride(from: 0, to: bytes.count, by: 4).allSatisfy { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self).littleEndian).isFinite }
                  }) else { throw PocketRuntimeError.invalidAudio }
            pcm = decoded
            totalFrames += event.frames
            nextSequence += 1
        }
        return .init(requestID: requestID, itemIndex: 0, sequenceIndex: nextSequence,
            sampleRate: 24000, audioData: pcm, durationSeconds: Double(final ? totalFrames : event.frames) / 24000,
            isFinal: final, elapsedSeconds: event.generationSeconds, device: "cpu")
    }

    private struct Event: Decodable {
        let type: String
        let id: String
        let sequence: Int
        let frames: Int
        let pcm: String?
        let generationSeconds: Double?
    }
}
