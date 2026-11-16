import CryptoKit
import Darwin
import Foundation

/// A fixed public stock-model manifest; contains no credentials or voice samples.
struct PocketAssetManifest: Codable, Equatable, Sendable {
    struct Asset: Codable, Equatable, Sendable {
        let name: String
        let url: URL
        let bytes: Int64
        let sha256: String
    }
    let schema: Int
    let pocketVersion, model, modelRevision, voice: String
    let assets: [Asset]

    static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "pocket-assets", withExtension: "json") else {
            throw PocketRuntimeError.setupFailed("the app resources")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func hasCompleteReceipt(at root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(Self.self, from: data), receipt == self else { return false }
        return assets.allSatisfy {
            let values = try? root.appendingPathComponent("assets/\($0.name)").resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true && Int64(values?.fileSize ?? -1) == $0.bytes
        }
    }

    static func verifies(_ asset: Asset, at file: URL) throws -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}

/// Full and Mini share assets. An advisory file lock also survives app crashes
/// correctly: the OS releases it, unlike a persistent "installing" marker.
final class PocketInstallLock: @unchecked Sendable {
    private let descriptor: Int32
    init(at path: URL) throws {
        descriptor = open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PocketRuntimeError.setupFailed("the installation folder") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PocketRuntimeError.busy
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

struct PocketAssetInstaller: Sendable {
    let manifest: PocketAssetManifest

    func prepare(at staging: URL, reusing installedRoot: URL? = nil,
                 progress: @escaping @Sendable (PocketInstallProgress) async -> Void) async throws {
        let manager = FileManager.default
        let assets = staging.appendingPathComponent("assets", isDirectory: true)
        try manager.createDirectory(at: assets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A process killed between transfer completion and verification can leave
        // a temporary download. Only remove our UUID-named staging files.
        for file in try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            if name.hasPrefix("download-"), UUID(uuidString: String(name.dropFirst(9))) != nil {
                try manager.removeItem(at: file)
            }
        }
        let total = manifest.assets.reduce(Int64(0)) { $0 + $1.bytes }
        let available = try staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let missing = manifest.assets.reduce(Int64(0)) { sum, asset in
            sum + ((try? PocketAssetManifest.verifies(asset, at: assets.appendingPathComponent(asset.name))) == true ? 0 : asset.bytes)
        }
        // Download temporary files can live on a different volume; leave headroom.
        if let available, available < missing * 2 + 64 * 1024 * 1024 { throw PocketRuntimeError.insufficientSpace }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 900
        var complete: Int64 = 0
        for asset in manifest.assets {
            try Task.checkCancellation()
            let destination = assets.appendingPathComponent(asset.name)
            if try PocketAssetManifest.verifies(asset, at: destination) { complete += asset.bytes; continue }
            if let existing = installedRoot?.appendingPathComponent("assets/\(asset.name)"),
               try PocketAssetManifest.verifies(asset, at: existing) {
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.copyItem(at: existing, to: destination)
                complete += asset.bytes
                continue
            }
            let resumeURL = staging.appendingPathComponent(asset.name + ".resume")
            let alreadyComplete = complete
            let updates = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let observer = Task {
                var lastUpdate = Date.distantPast
                for await bytes in updates.stream {
                    guard Date().timeIntervalSince(lastUpdate) >= 0.1 || bytes >= asset.bytes else { continue }
                    lastUpdate = Date()
                    let count = min(total, alreadyComplete + min(asset.bytes, max(0, bytes)))
                    await progress(.init(stage: "Downloading Pocket", fraction: 0.05 + 0.8 * Double(count) / Double(total), downloadedBytes: count, totalBytes: total))
                }
            }
            let download = PocketAssetDownload(configuration: configuration, staging: staging, resumeURL: resumeURL) {
                updates.continuation.yield($0)
            }
            do {
                let result: (URL, URLResponse)
                if let resume = try? Data(contentsOf: resumeURL) {
                    do { result = try await download.start(url: asset.url, resumeData: resume) }
                    catch {
                        if Task.isCancelled { throw error }
                        try? manager.removeItem(at: resumeURL)
                        result = try await download.start(url: asset.url)
                    }
                } else { result = try await download.start(url: asset.url) }
                defer { try? manager.removeItem(at: result.0) }
                guard let response = result.1 as? HTTPURLResponse, (200...299).contains(response.statusCode),
                      try PocketAssetManifest.verifies(asset, at: result.0) else {
                    throw PocketRuntimeError.setupFailed("the model checksum")
                }
                try Task.checkCancellation()
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.moveItem(at: result.0, to: destination)
                try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                try? manager.removeItem(at: resumeURL)
                updates.continuation.finish()
                await observer.value
            } catch {
                if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    try? resume.write(to: resumeURL, options: .atomic)
                }
                updates.continuation.finish()
                await observer.value
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw error
            }
            complete += asset.bytes
        }
        // This is a staging receipt. The parent performs offline synthesis before
        // atomically publishing the directory the app actually uses.
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
    }

    static func activate(staging: URL, destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }
}

/// Explicit download tasks are needed for macOS progress callbacks. The async
/// convenience API installs an internal delegate that consumes those callbacks.
/// Mutable delegate state is protected by a lock; completion waits for resume
/// data on cancellation before releasing the cross-edition installation lease.
private final class PocketAssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let staging, resumeURL: URL
    private let update: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var result: Result<(URL, URLResponse), Error>?
    private var completed = false
    private var cancelled = false
    private var awaitingResume = false

    init(configuration: URLSessionConfiguration, staging: URL, resumeURL: URL, update: @escaping @Sendable (Int64) -> Void) {
        self.configuration = configuration; self.staging = staging; self.resumeURL = resumeURL; self.update = update
    }

    func start(url: URL, resumeData: Data? = nil) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                result = nil; completed = false
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        awaitingResume = task != nil
        lock.unlock()
        task?.cancel { resume in
            if let resume { try? resume.write(to: self.resumeURL, options: .atomic) }
            self.lock.lock(); self.awaitingResume = false; self.lock.unlock()
            self.finishIfReady()
        }
    }

    private func finishIfReady() {
        lock.lock()
        guard completed, !awaitingResume, let continuation, let result else { lock.unlock(); return }
        self.continuation = nil
        let session = self.session
        self.session = nil; task = nil
        let outcome: Result<(URL, URLResponse), Error> = cancelled ? .failure(CancellationError()) : result
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = staging.appendingPathComponent("download-" + UUID().uuidString)
        let outcome: Result<(URL, URLResponse), Error>
        do {
            guard let response = downloadTask.response else { throw PocketRuntimeError.setupFailed("the download response") }
            try FileManager.default.moveItem(at: location, to: destination)
            outcome = .success((destination, response))
        } catch { outcome = .failure(error) }
        lock.lock(); result = outcome; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resume.write(to: resumeURL, options: .atomic)
        }
        lock.lock()
        if let error {
            if case .success(let value) = result { try? FileManager.default.removeItem(at: value.0) }
            result = .failure(error)
        }
        if result == nil { result = .failure(PocketRuntimeError.setupFailed("the download")) }
        completed = true
        lock.unlock()
        finishIfReady()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
