import Foundation
import XCTest

final class QwenHelperBehaviorTests: XCTestCase {
    func testReferenceBatchingComparesTranscriptContentsRatherThanTemporaryPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("salient-qwen-helper-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let firstTranscript = root.appendingPathComponent("first.txt")
        let secondTranscript = root.appendingPathComponent("second.txt")
        let differentTranscript = root.appendingPathComponent("different.txt")
        try "Synthetic shared reference transcript.".write(
            to: firstTranscript,
            atomically: true,
            encoding: .utf8
        )
        try "Synthetic shared reference transcript.".write(
            to: secondTranscript,
            atomically: true,
            encoding: .utf8
        )
        try "A different synthetic reference transcript.".write(
            to: differentTranscript,
            atomically: true,
            encoding: .utf8
        )

        let result = try runHelperProbe(
            firstTranscript: firstTranscript,
            secondTranscript: secondTranscript,
            differentTranscript: differentTranscript
        )

        XCTAssertEqual(result["sameTranscriptCanBatchByDefault"] as? Bool, false)
        XCTAssertEqual(result["sameTranscriptCanBatchWhenOptedIn"] as? Bool, true)
        XCTAssertEqual(result["differentTranscriptCanBatch"] as? Bool, false)
        XCTAssertEqual(result["differentAudioCanBatch"] as? Bool, false)
        XCTAssertEqual(result["batchVoicesAreNil"] as? Bool, true)
        XCTAssertEqual(result["referenceRepetitionPenalty"] as? Double, 1.1)
    }

    private func runHelperProbe(
        firstTranscript: URL,
        secondTranscript: URL,
        differentTranscript: URL
    ) throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = projectRoot
            .appendingPathComponent("Sources/SalientCore/Resources/qwen_tts_helper.py")
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("The helper behavior test requires the system Python runtime.")
        }

        let script = #"""
            import importlib.util
            import json
            import os
            import sys

            helper_path, first_path, second_path, different_path = sys.argv[1:5]
            spec = importlib.util.spec_from_file_location("salient_qwen_helper", helper_path)
            helper = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(helper)

            class Result:
                def __init__(self, index):
                    self.sequence_idx = index
                    self.audio = [0.0]
                    self.sample_rate = 24000

            class Model:
                def __init__(self):
                    self.kwargs = None

                def batch_generate(self, texts, **kwargs):
                    self.kwargs = kwargs
                    return [Result(index) for index, _ in enumerate(texts)]

            def item(transcript, audio="synthetic-reference.wav", speaker="Aiden", index=0):
                return {
                    "text_file": transcript,
                    "output": transcript + f"-{index}.wav",
                    "speaker": speaker,
                    "language": "English",
                    "ref_audio": audio,
                    "ref_text_file": transcript,
                }

            same = [item(first_path, speaker="Aiden", index=0), item(second_path, speaker="Ryan", index=1)]
            different_text = [item(first_path, index=0), item(different_path, index=1)]
            different_audio = [item(first_path, audio="one.wav", index=0), item(second_path, audio="two.wav", index=1)]
            model = Model()
            helper._synthesize_batch(model, same, lambda *args, **kwargs: None)
            os.environ.pop("SALIENT_QWEN_REFERENCE_BATCHING", None)
            same_default = helper._can_batch(Model(), same)
            os.environ["SALIENT_QWEN_REFERENCE_BATCHING"] = "true"
            print(json.dumps({
                "sameTranscriptCanBatchByDefault": same_default,
                "sameTranscriptCanBatchWhenOptedIn": helper._can_batch(Model(), same),
                "differentTranscriptCanBatch": helper._can_batch(Model(), different_text),
                "differentAudioCanBatch": helper._can_batch(Model(), different_audio),
                "batchVoicesAreNil": all(voice is None for voice in model.kwargs["voices"]),
                "referenceRepetitionPenalty": model.kwargs["repetition_penalty"],
            }), flush=True)
            """#

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            script,
            helperURL.path,
            firstTranscript.path,
            secondTranscript.path,
            differentTranscript.path,
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorData, encoding: .utf8) ?? "Python helper probe failed."
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: outputData) as? [String: Any]
        )
    }
}
