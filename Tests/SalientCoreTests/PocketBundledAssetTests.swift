import CryptoKit
import Foundation
import XCTest
@testable import SalientCore

/// Packaged editions sign stock assets into Contents/Resources/PocketTTS. These
/// synthetic fixtures never contain real weights and never touch the network.
final class PocketBundledAssetTests: XCTestCase {
    private static let contents: [String: Data] = [
        "model.safetensors": Data("synthetic model".utf8),
        "tokenizer.json": Data("{\"synthetic\":true}".utf8),
        "alba.safetensors": Data("synthetic voice".utf8)
    ]

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func syntheticManifest(revision: String = "synthetic") -> PocketAssetManifest {
        let assets = ["model.safetensors", "tokenizer.json", "alba.safetensors"].map { name in
            let data = Self.contents[name]!
            return PocketAssetManifest.Asset(name: name, url: URL(string: "https://invalid.example/never-download")!,
                bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return PocketAssetManifest(schema: 2, pocketVersion: PocketRuntimeManager.version, model: "fixture",
                                   modelRevision: revision, voice: "alba", assets: assets)
    }

    private func writeAssets(at root: URL, receipt: PocketAssetManifest) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        for (name, data) in Self.contents { try data.write(to: root.appendingPathComponent("assets/\(name)")) }
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("receipt.json"))
        try Data("Synthetic notices".utf8).write(to: root.appendingPathComponent("NOTICES.md"))
    }

    /// Readiness checks never launch this; only its executable bit matters there.
    private func fakeWorker(in directory: URL, expectingRoot: URL? = nil) throws -> URL {
        let worker = directory.appendingPathComponent("salient-pocket-worker")
        let check = expectingRoot.map { "[ \"$1\" = --root ] && [ \"$2\" = '\($0.path)' ] && [ \"$3\" = --int8 ] || exit 3\n" } ?? "exit 3\n"
        let ready = "{\"type\":\"ready\",\"schema\":2,\"version\":\"\(PocketRuntimeManager.version)\"}"
        let script = "#!/bin/sh\n" + check + "printf '%s\\n' '\(ready)'\nexec cat >/dev/null\n"
        try Data(script.utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        return worker
    }

    private func snapshot(_ root: URL) -> [String: Date] {
        var result: [String: Date] = [:]
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return result }
        for case let file as URL in files {
            result[file.path] = (try? file.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
        }
        return result
    }

    func testFreshPackagedInstallIsReadyFromTheBundleWithoutWriting() async throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let managed = base.appendingPathComponent("Application Support/native-v2", isDirectory: true)
        let bundle = base.appendingPathComponent("Salient.app/Contents/Resources/PocketTTS", isDirectory: true)
        let manifest = syntheticManifest()
        try writeAssets(at: bundle, receipt: manifest)
        let before = snapshot(bundle)
        let runtime = PocketRuntimeManager(root: managed, workerURL: try fakeWorker(in: base), bundledRoot: bundle, manifest: manifest)
        let resolved = await runtime.resolvedAssetRoot()
        let ready = await runtime.isInstalled()
        XCTAssertEqual(resolved, bundle)
        XCTAssertTrue(ready)
        XCTAssertEqual(runtime.root, managed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.deletingLastPathComponent().path))
        XCTAssertEqual(snapshot(bundle), before)
    }

    func testInvalidMismatchedOrMalformedBundleIsNotReady() async throws {
        let manifest = syntheticManifest()
        let mismatched = syntheticManifest(revision: "other")
        let cases: [(String, (URL) throws -> Void)] = [
            ("empty bundle", { _ in }),
            ("missing receipt", { root in
                try self.writeAssets(at: root, receipt: manifest)
                try FileManager.default.removeItem(at: root.appendingPathComponent("receipt.json"))
            }),
            ("malformed receipt", { root in
                try self.writeAssets(at: root, receipt: manifest)
                try Data("not a receipt".utf8).write(to: root.appendingPathComponent("receipt.json"))
            }),
            ("mismatched receipt", { root in try self.writeAssets(at: root, receipt: mismatched) }),
            ("missing asset", { root in
                try self.writeAssets(at: root, receipt: manifest)
                try FileManager.default.removeItem(at: root.appendingPathComponent("assets/alba.safetensors"))
            }),
            ("wrong-sized asset", { root in
                try self.writeAssets(at: root, receipt: manifest)
                try Data("short".utf8).write(to: root.appendingPathComponent("assets/tokenizer.json"))
            }),
            ("symlinked asset", { root in
                try self.writeAssets(at: root, receipt: manifest)
                let model = root.appendingPathComponent("assets/model.safetensors")
                let elsewhere = root.appendingPathComponent("model-copy")
                try FileManager.default.moveItem(at: model, to: elsewhere)
                try FileManager.default.createSymbolicLink(at: model, withDestinationURL: elsewhere)
            }),
            ("directory in place of asset", { root in
                try self.writeAssets(at: root, receipt: manifest)
                let voice = root.appendingPathComponent("assets/alba.safetensors")
                try FileManager.default.removeItem(at: voice)
                try FileManager.default.createDirectory(at: voice, withIntermediateDirectories: false)
            })
        ]
        for (name, prepare) in cases {
            let base = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: base) }
            let bundle = base.appendingPathComponent("PocketTTS", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try prepare(bundle)
            let runtime = PocketRuntimeManager(root: base.appendingPathComponent("managed"), workerURL: try fakeWorker(in: base),
                                               bundledRoot: bundle, manifest: manifest)
            let resolved = await runtime.resolvedAssetRoot()
            let ready = await runtime.isInstalled()
            XCTAssertNil(resolved, name)
            XCTAssertFalse(ready, name)
            do { try await runtime.warm(); XCTFail("\(name) became resident") }
            catch { XCTAssertEqual(error as? PocketRuntimeError, .needsSetup, name) }
        }
    }

    func testProductionManifestRejectsTinyStandInsThroughPublicInit() async throws {
        // A genuine stock receipt beside tiny files must fail the size checks.
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let bundle = base.appendingPathComponent("PocketTTS", isDirectory: true)
        let production = try PocketAssetManifest.bundled()
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try JSONEncoder().encode(production).write(to: bundle.appendingPathComponent("receipt.json"))
        for asset in production.assets { try Data("tiny".utf8).write(to: bundle.appendingPathComponent("assets/\(asset.name)")) }
        let runtime = PocketRuntimeManager(root: base.appendingPathComponent("managed"), workerURL: try fakeWorker(in: base), bundledRoot: bundle)
        XCTAssertEqual(runtime.bundledRoot, bundle)
        let resolved = await runtime.resolvedAssetRoot()
        let ready = await runtime.isInstalled()
        XCTAssertNil(resolved)
        XCTAssertFalse(ready)
    }

    func testCompleteManagedInstallTakesPrecedenceAndBrokenManagedFallsBackToBundle() async throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let managed = base.appendingPathComponent("managed", isDirectory: true)
        let bundle = base.appendingPathComponent("PocketTTS", isDirectory: true)
        let manifest = syntheticManifest()
        try writeAssets(at: managed, receipt: manifest)
        try writeAssets(at: bundle, receipt: manifest)
        let runtime = PocketRuntimeManager(root: managed, workerURL: try fakeWorker(in: base), bundledRoot: bundle, manifest: manifest)
        let preferred = await runtime.resolvedAssetRoot()
        XCTAssertEqual(preferred, managed)
        try Data("short".utf8).write(to: managed.appendingPathComponent("assets/model.safetensors"))
        let fallback = await runtime.resolvedAssetRoot()
        let ready = await runtime.isInstalled()
        XCTAssertEqual(fallback, bundle)
        XCTAssertTrue(ready)
    }

    func testExplicitRootsStayIsolatedFromBundledAssets() async throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let staging = base.appendingPathComponent("native-v2.staging", isDirectory: true)
        let bundle = base.appendingPathComponent("PocketTTS", isDirectory: true)
        let manifest = syntheticManifest()
        try writeAssets(at: bundle, receipt: manifest)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let worker = try fakeWorker(in: base)

        // Probes and staging validation pass only `root`; no implicit fallback.
        XCTAssertNil(PocketRuntimeManager(root: staging, workerURL: worker).bundledRoot)
        XCTAssertEqual(PocketRuntimeManager(root: staging, workerURL: worker, bundledRoot: bundle).bundledRoot, bundle)
        // The default instance adopts the host app's bundle. An XCTest host is
        // not an .app, so nothing is discovered here.
        XCTAssertEqual(PocketRuntimeManager().bundledRoot, PocketRuntimeManager.bundledAssetRoot)
        if Bundle.main.bundleURL.pathExtension != "app" { XCTAssertNil(PocketRuntimeManager.bundledAssetRoot) }

        let candidate = PocketRuntimeManager(root: staging, workerURL: worker, bundledRoot: nil, manifest: manifest)
        let resolved = await candidate.resolvedAssetRoot()
        let ready = await candidate.isInstalled()
        XCTAssertNil(resolved)
        XCTAssertFalse(ready)
        do { try await candidate.warm(); XCTFail("Invalid staging borrowed bundled assets") }
        catch { XCTAssertEqual(error as? PocketRuntimeError, .needsSetup) }
    }

    func testMissingWorkerIsNotReadyEvenWithValidBundle() async throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let bundle = base.appendingPathComponent("PocketTTS", isDirectory: true)
        let manifest = syntheticManifest()
        try writeAssets(at: bundle, receipt: manifest)
        let runtime = PocketRuntimeManager(root: base.appendingPathComponent("managed"), workerURL: base.appendingPathComponent("absent-worker"),
                                           bundledRoot: bundle, manifest: manifest)
        let resolved = await runtime.resolvedAssetRoot()
        let ready = await runtime.isInstalled()
        XCTAssertEqual(resolved, bundle)
        XCTAssertFalse(ready)
    }

    func testWorkerLaunchesAgainstTheResolvedAssetRoot() async throws {
        guard try sandboxExecCanApplyProfiles() else {
            throw XCTSkip("This host cannot nest sandbox-exec, so the worker launch path cannot run here.")
        }
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let managed = base.appendingPathComponent("managed", isDirectory: true)
        let bundle = base.appendingPathComponent("PocketTTS", isDirectory: true)
        let manifest = syntheticManifest()
        try writeAssets(at: bundle, receipt: manifest)

        // The fake worker announces readiness only when given the expected root.
        let bundledRuntime = PocketRuntimeManager(root: managed, workerURL: try fakeWorker(in: base, expectingRoot: bundle),
                                                  bundledRoot: bundle, manifest: manifest)
        try await bundledRuntime.warm()
        let bundledResident = await bundledRuntime.isResident()
        XCTAssertTrue(bundledResident)
        await bundledRuntime.unload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))

        try writeAssets(at: managed, receipt: manifest)
        let workerDirectory = base.appendingPathComponent("managed-worker", isDirectory: true)
        try FileManager.default.createDirectory(at: workerDirectory, withIntermediateDirectories: true)
        let managedRuntime = PocketRuntimeManager(root: managed, workerURL: try fakeWorker(in: workerDirectory, expectingRoot: managed),
                                                  bundledRoot: bundle, manifest: manifest)
        try await managedRuntime.warm()
        let managedResident = await managedRuntime.isResident()
        XCTAssertTrue(managedResident)
        await managedRuntime.unload()
        let unloaded = await managedRuntime.isResident()
        XCTAssertFalse(unloaded)
    }

    private func sandboxExecCanApplyProfiles() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", "(version 1) (allow default) (deny network*)", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
