import Foundation
import XCTest

final class PackageResourcePolicyTests: XCTestCase {
    func testSalientCoreResourcesAreWhitelistedInPackageManifest() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)

        XCTAssertFalse(package.contains(#".process("Resources")"#))
        for resource in [
            "safari_capture.js",
            "safari_highlight.js",
            "submit.js",
            "two-pane.html",
            "qwen_tts_helper.py",
            "pocket-assets.json",
            "Pocket-Notices.md"
        ] {
            XCTAssertTrue(package.contains(#".process("Resources/\#(resource)")"#), "Missing resource whitelist entry for \(resource)")
        }
        XCTAssertFalse(package.contains("local_librarian_helper.py"))
        XCTAssertTrue(package.contains(#""Resources/Voices""#))
        XCTAssertFalse(package.contains(#""Resources/__pycache__""#))
    }

    func testBuildScriptRejectsGeneratedResourceArtifacts() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("reject_forbidden_resource_artifacts"))
        XCTAssertTrue(script.contains("*.pyc"))
        XCTAssertTrue(script.contains("*.wav"))
        XCTAssertTrue(script.contains("*.sqlite*"))
    }

    func testBuildScriptEmbedsVerifiedPocketAssetsBeforeSigningWithoutRelaxingScan() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        let coreCopy = try XCTUnwrap(script.range(of: "Missing core resources"))
        let embed = try XCTUnwrap(script.range(of: #""$POCKET_ASSETS_TOOL" embed "$APP_RESOURCES" --offline"#))
        let scan = try XCTUnwrap(script.range(of: #"reject_forbidden_resource_artifacts "$APP_RESOURCES""#))
        let firstSignature = try XCTUnwrap(script.range(of: "/usr/bin/codesign --force"))
        XCTAssertLessThan(coreCopy.lowerBound, embed.lowerBound)
        XCTAssertLessThan(embed.lowerBound, scan.lowerBound)
        XCTAssertLessThan(scan.lowerBound, firstSignature.lowerBound)
        XCTAssertTrue(script.contains(#"python3 "$POCKET_ASSETS_TOOL" scan "$search_root" --require-pocket"#))
        // Only the two exact manifest weight paths are exempt; no wildcard exception.
        XCTAssertTrue(script.contains(#"-path "$search_root/PocketTTS/assets/model.safetensors""#))
        XCTAssertTrue(script.contains(#"-path "$search_root/PocketTTS/assets/alba.safetensors""#))
        XCTAssertFalse(script.contains(#"*PocketTTS"#))
        XCTAssertFalse(script.contains(#"PocketTTS/*"#))
        XCTAssertFalse(script.contains(#"-path "*.safetensors""#))
        XCTAssertFalse(script.contains(#"! -name "*.safetensors""#))
        XCTAssertFalse(script.contains("Application Support/Salient/PocketTTS"))
    }

    func testReleaseVerifiesBundledPocketAndExplainsOfflineSetup() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("script/release.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains(#"package_pocket_assets.py" verify-bundle "$stage/$NAME.app/Contents/Resources""#))
        XCTAssertTrue(script.contains("Pocket TTS with the Alba voice is included and ready offline"))
        XCTAssertTrue(script.contains("Browser study controls are set up separately"))
        XCTAssertTrue(script.contains(#"shasum -a 256 "$(basename "$artifact")""#))
        XCTAssertTrue(script.contains("Refusing to submit an app without a Developer ID signature."))
    }

    func testSourcesContainNoModelWeights() throws {
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var weights: [String] = []
        for case let url as URL in enumerator
        where ["safetensors", "gguf", "pt", "pth", "ckpt", "onnx"].contains(url.pathExtension.lowercased()) {
            weights.append(url.path)
        }
        XCTAssertEqual(weights, [])
    }

    func testBuildScriptRegistersAndSoakTestsPackagedAppWithoutTerminatingIt() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("CFBundleShortVersionString"))
        XCTAssertTrue(script.contains("CFBundleVersion"))
        XCTAssertTrue(script.contains("lsregister"))
        XCTAssertTrue(script.contains(#"ln -s "../Resources/mlx.metallib" "$APP_MACOS/mlx.metallib""#))
        XCTAssertTrue(script.contains("verify_app_stability"))
        XCTAssertTrue(script.contains("remained running for the 15-second launch verification"))
    }

    func testBuildScriptKeepsInteractiveFlowsDebugAndPackagesRelease() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains(#"BUILD_CONFIGURATION="debug""#))
        XCTAssertTrue(script.contains(#"BUILD_CONFIGURATION="release""#))
        XCTAssertTrue(script.contains(#"package|--release|release"#))
        XCTAssertTrue(script.contains(#"swift build --configuration "$BUILD_CONFIGURATION" --product "$APP_NAME""#))
        XCTAssertTrue(script.contains(#"BUILD_BINARY="$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)/$APP_NAME""#))
        XCTAssertTrue(script.contains("Packaged $BUILD_CONFIGURATION app bundle at $APP_BUNDLE"))
    }

    private var repoRoot: URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
