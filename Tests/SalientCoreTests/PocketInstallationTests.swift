import CryptoKit
import Foundation
import XCTest
@testable import SalientCore

final class PocketInstallationTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func asset(for data: Data) -> PocketAssetManifest.Asset {
        .init(name: "fixture.bin", url: URL(string: "https://invalid.example/never-download")!, bytes: Int64(data.count),
              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testAssetIntegrityRejectsSameLengthCorruptionTruncationAndSymlinks() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("synthetic".utf8)
        let asset = asset(for: original)
        let path = root.appendingPathComponent(asset.name)
        try original.write(to: path)
        XCTAssertTrue(try PocketAssetManifest.verifies(asset, at: path))
        try Data("corrupted".utf8).write(to: path)
        XCTAssertFalse(try PocketAssetManifest.verifies(asset, at: path))
        try Data("short".utf8).write(to: path)
        XCTAssertFalse(try PocketAssetManifest.verifies(asset, at: path))
        let link = root.appendingPathComponent("link")
        try original.write(to: path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertFalse(try PocketAssetManifest.verifies(asset, at: link))
    }

    func testCrossEditionInstallLockIsReleasedWithoutDeletingTheLockFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("install.lock")
        var first: PocketInstallLock? = try PocketInstallLock(at: path)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try PocketInstallLock(at: path)) { XCTAssertEqual($0 as? PocketRuntimeError, .busy) }
        first = nil
        let next = try PocketInstallLock(at: path)
        withExtendedLifetime(next) {}
    }

    func testVerifiedStagingResumesWithoutNetworkAndPublishesTogether() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        let destination = root.appendingPathComponent("active")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let old = destination.appendingPathComponent("keep-until-ready")
        try Data("previous".utf8).write(to: old)
        let data = Data("synthetic".utf8)
        let asset = asset(for: data)
        let manifest = PocketAssetManifest(schema: 2, pocketVersion: "test", model: "fixture", modelRevision: "test", voice: "alba", assets: [asset])
        try data.write(to: staging.appendingPathComponent("assets/fixture.bin"))
        let abandoned = staging.appendingPathComponent("download-" + UUID().uuidString)
        let unrelated = staging.appendingPathComponent("download-not-a-uuid")
        try data.write(to: abandoned)
        try data.write(to: unrelated)
        try await PocketAssetInstaller(manifest: manifest).prepare(at: staging) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(manifest.hasCompleteReceipt(at: destination))
        XCTAssertTrue(manifest.hasCompleteReceipt(at: staging))
        try PocketAssetInstaller.activate(staging: staging, destination: destination)
        XCTAssertTrue(manifest.hasCompleteReceipt(at: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testReceiptCannotMarkMissingOrWrongSizedAssetsReady() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try PocketAssetManifest.bundled()
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("receipt.json"))
        XCTAssertFalse(manifest.hasCompleteReceipt(at: root))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        for asset in manifest.assets { try Data().write(to: root.appendingPathComponent("assets/\(asset.name)")) }
        XCTAssertFalse(manifest.hasCompleteReceipt(at: root))
    }

    func testRepairReusesVerifiedActiveAssetsWithoutTouchingTheActiveInstall() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: active.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let data = Data("synthetic".utf8)
        let asset = asset(for: data)
        let manifest = PocketAssetManifest(schema: 2, pocketVersion: "test", model: "fixture", modelRevision: "test", voice: "alba", assets: [asset])
        let original = active.appendingPathComponent("assets/fixture.bin")
        try data.write(to: original)
        try await PocketAssetInstaller(manifest: manifest).prepare(at: staging, reusing: active) { _ in }
        XCTAssertTrue(manifest.hasCompleteReceipt(at: staging))
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertFalse(manifest.hasCompleteReceipt(at: active))
    }
}
