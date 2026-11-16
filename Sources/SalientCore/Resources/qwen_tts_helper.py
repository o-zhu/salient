#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


DEFAULT_MAX_TOKENS = 1200
REFERENCE_REPETITION_PENALTY = 1.1


def _json(payload: dict[str, object], stream: Any | None = None) -> None:
    print(json.dumps(payload, sort_keys=True), file=stream or sys.stdout, flush=True)


def _quiet_call(func: Any, *args: Any, **kwargs: Any) -> Any:
    with contextlib.redirect_stdout(io.StringIO()):
        return func(*args, **kwargs)


def _redacted_error(exc: Exception) -> str:
    return exc.__class__.__name__


def doctor(_: argparse.Namespace) -> int:
    try:
        import huggingface_hub  # noqa: F401
        import mlx_audio  # noqa: F401
    except Exception as exc:
        _json({"ok": False, "error": str(exc)})
        return 1
    _json({"ok": True})
    return 0


def synthesize(args: argparse.Namespace) -> int:
    text = Path(args.text_file).read_text(encoding="utf-8").strip()
    if not text:
        _json({"ok": False, "error": "empty text"})
        return 2
    ref_text = None
    if args.ref_text_file:
        ref_text = Path(args.ref_text_file).read_text(encoding="utf-8").strip() or None

    from mlx_audio.tts.generate import generate_audio
    from mlx_audio.tts.utils import load_model

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="salient-qwen-") as tmp_name:
        tmp_dir = Path(tmp_name)
        file_prefix = "qwen_chunk"
        model = _quiet_call(load_model, model_path=args.model)
        _quiet_call(
            generate_audio,
            text=text,
            model=model,
            voice=args.speaker,
            speed=1.0,
            lang_code=args.language,
            ref_audio=args.ref_audio,
            ref_text=ref_text,
            output_path=str(tmp_dir),
            file_prefix=file_prefix,
            audio_format="wav",
            join_audio=True,
            play=False,
            verbose=False,
            max_tokens=DEFAULT_MAX_TOKENS,
            temperature=0.5,
            top_p=0.9,
            top_k=50,
            repetition_penalty=1.1,
        )
        generated = _detect_output(tmp_dir, file_prefix)
        shutil.move(str(generated), str(output))
    _json({"ok": True, "output": str(output), "bytes": output.stat().st_size})
    return 0


def serve(args: argparse.Namespace) -> int:
    from mlx_audio.audio_io import write as audio_write
    from mlx_audio.tts.generate import generate_audio
    from mlx_audio.tts.utils import load_model

    load_started = time.monotonic()
    model = _quiet_call(load_model, model_path=args.model)
    _json({"ok": True, "event": "ready", "modelLoadSeconds": time.monotonic() - load_started})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        started = time.monotonic()
        try:
            payload = json.loads(line)
            request_id = str(payload.get("id", ""))
            items = payload.get("items")
            if not isinstance(items, list) or not items:
                raise ValueError("request items must be a non-empty list")

            if str(payload.get("mode", "")) == "stream":
                try:
                    _stream_items(
                        model,
                        items,
                        request_id=request_id,
                        streaming_interval=float(payload.get("streaming_interval", 0.32) or 0.32),
                        started=started,
                    )
                except Exception as exc:
                    _json({
                        "id": request_id,
                        "request_id": request_id,
                        "ok": False,
                        "event": "stream_error",
                        "error": _redacted_error(exc),
                        "elapsed_seconds": time.monotonic() - started,
                        "peak_mlx_memory_bytes": _peak_mlx_memory_bytes(),
                        "mlx_device": _mlx_device_name(),
                    })
                    raise
                continue

            if _can_batch(model, items):
                _synthesize_batch(model, items, audio_write)
                mode = "batch"
            else:
                for index, item in enumerate(items):
                    _synthesize_serial_item(model, item, generate_audio, f"{request_id}-{index}")
                mode = "serial"

            response_items = [
                {
                    "output": str(Path(str(item["output"]))),
                    "bytes": Path(str(item["output"])).stat().st_size,
                }
                for item in items
            ]
            _json({
                "id": request_id,
                "ok": True,
                "mode": mode,
                "items": response_items,
                "processSeconds": time.monotonic() - started,
            })
        except Exception as exc:
            request_id = ""
            try:
                request_id = str(json.loads(line).get("id", ""))
            except Exception:
                pass
            _json({
                "id": request_id,
                "ok": False,
                "error": _redacted_error(exc),
                "processSeconds": time.monotonic() - started,
            })
    return 0


def _can_batch(model: Any, items: list[dict[str, Any]]) -> bool:
    if len(items) < 2 or not hasattr(model, "batch_generate"):
        return False
    languages = {str(item.get("language", "")) for item in items}
    speakers = {str(item.get("speaker", "")) for item in items}
    any_refs = any(item.get("ref_audio") or item.get("ref_text_file") for item in items)
    shared_ref_audio, shared_ref_text = _shared_reference_values(items)
    if len(languages) != 1:
        return False
    if any_refs:
        # mlx-audio 0.4.4's Qwen3 ICL batch path derives a shorter token cap
        # than its serial ICL path. Keep reference batching experimental so a
        # speed optimization cannot truncate or destabilize cloned speech.
        return (
            _reference_batching_enabled()
            and shared_ref_audio is not None
            and shared_ref_text is not None
        )
    if len(speakers) != 1:
        return False
    supports_batch = getattr(model, "supports_tts_batch", None)
    if supports_batch is None:
        return True
    return bool(_quiet_call(
        supports_batch,
        stream=False,
        voice=next(iter(speakers)) or None,
        speed=1.0,
    ))


def _reference_batching_enabled() -> bool:
    value = os.environ.get("SALIENT_QWEN_REFERENCE_BATCHING", "")
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _synthesize_batch(model: Any, items: list[dict[str, Any]], audio_write: Any) -> None:
    texts = [_read_text_file(item) for item in items]
    shared_ref_audio, shared_ref_text = _shared_reference_values(items)
    voice = None if shared_ref_audio is not None else str(items[0].get("speaker", "")) or None
    speakers = [voice] * len(items) if shared_ref_audio is not None else [str(item.get("speaker", "")) or None for item in items]
    language = str(items[0].get("language", "auto")) or "auto"
    repetition_penalty = REFERENCE_REPETITION_PENALTY if shared_ref_audio is not None else 1.1
    with contextlib.redirect_stdout(io.StringIO()):
        results = list(model.batch_generate(
            texts,
            voices=speakers,
            ref_audio=shared_ref_audio,
            ref_text=shared_ref_text,
            temperature=0.5,
            lang_code=language,
            max_tokens=DEFAULT_MAX_TOKENS,
            top_p=0.9,
            top_k=50,
            repetition_penalty=repetition_penalty,
            stream=False,
            verbose=False,
        ))
    if len(results) != len(items):
        raise RuntimeError("Qwen batch did not return the expected number of outputs.")
    for result in results:
        index = int(getattr(result, "sequence_idx", len(results)))
        if index < 0 or index >= len(items):
            raise RuntimeError("Qwen batch returned an out-of-range sequence index.")
        output = Path(str(items[index]["output"]))
        output.parent.mkdir(parents=True, exist_ok=True)
        audio_write(str(output), result.audio, int(result.sample_rate), format="wav")


def _stream_items(
    model: Any,
    items: list[dict[str, Any]],
    *,
    request_id: str,
    streaming_interval: float,
    started: float,
) -> None:
    _json({
        "id": request_id,
        "request_id": request_id,
        "ok": True,
        "event": "stream_start",
        "item_count": len(items),
        "elapsed_seconds": time.monotonic() - started,
        "peak_mlx_memory_bytes": _peak_mlx_memory_bytes(),
        "mlx_device": _mlx_device_name(),
    })
    for sequence_idx, item in enumerate(items):
        event_stream = sys.stdout
        text = _read_text_file(item)
        ref_text = None
        if item.get("ref_text_file"):
            ref_text = Path(str(item["ref_text_file"])).read_text(encoding="utf-8").strip() or None
        ref_audio = item.get("ref_audio") or None
        voice = None if ref_audio else str(item.get("speaker", "")) or None
        repetition_penalty = REFERENCE_REPETITION_PENALTY if ref_audio else 1.1
        item_index = int(item.get("item_index", sequence_idx))
        emitted_chunks = 0
        with contextlib.redirect_stdout(io.StringIO()):
            results = model.generate(
                text=text,
                voice=voice,
                lang_code=str(item.get("language", "auto")) or "auto",
                ref_audio=ref_audio,
                ref_text=ref_text,
                temperature=0.5,
                max_tokens=DEFAULT_MAX_TOKENS,
                top_p=0.9,
                top_k=50,
                repetition_penalty=repetition_penalty,
                stream=True,
                streaming_interval=streaming_interval,
            )
            for result in results:
                audio_bytes, sample_rate, duration_seconds = _audio_payload(result)
                emitted_chunks += 1
                _json({
                    "id": request_id,
                    "request_id": request_id,
                    "ok": True,
                    "event": "audio_chunk",
                    "item_index": item_index,
                    "sequence_idx": int(getattr(result, "sequence_idx", sequence_idx)),
                    "sample_rate": sample_rate,
                    "chunk_duration_seconds": duration_seconds,
                    "audio_b64": base64.b64encode(audio_bytes).decode("ascii"),
                    "is_final_chunk": bool(getattr(result, "is_final_chunk", False)),
                    "elapsed_seconds": time.monotonic() - started,
                    "peak_mlx_memory_bytes": _peak_mlx_memory_bytes(),
                    "mlx_device": _mlx_device_name(),
                }, stream=event_stream)
        _json({
            "id": request_id,
            "request_id": request_id,
            "ok": True,
            "event": "stream_item_done",
            "item_index": item_index,
            "sequence_idx": sequence_idx,
            "chunk_count": emitted_chunks,
            "elapsed_seconds": time.monotonic() - started,
            "peak_mlx_memory_bytes": _peak_mlx_memory_bytes(),
            "mlx_device": _mlx_device_name(),
        })
    _json({
        "id": request_id,
        "request_id": request_id,
        "ok": True,
        "event": "stream_done",
        "elapsed_seconds": time.monotonic() - started,
        "peak_mlx_memory_bytes": _peak_mlx_memory_bytes(),
        "mlx_device": _mlx_device_name(),
    })


def _audio_payload(result: Any) -> tuple[bytes, int, float]:
    import numpy as np

    audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
    sample_rate = int(getattr(result, "sample_rate", 24000) or 24000)
    duration_seconds = float(audio.shape[0]) / float(sample_rate) if sample_rate > 0 else 0.0
    return audio.tobytes(), sample_rate, duration_seconds


def _peak_mlx_memory_bytes() -> int | None:
    try:
        import mlx.core as mx

        return int(mx.get_peak_memory())
    except Exception:
        return None


def _mlx_device_name() -> str | None:
    try:
        import mlx.core as mx

        return str(mx.default_device())
    except Exception:
        return None


def _shared_reference_values(items: list[dict[str, Any]]) -> tuple[str | None, str | None]:
    ref_audios = {str(item.get("ref_audio") or "") for item in items}
    ref_audios.discard("")
    ref_texts = {
        Path(str(item["ref_text_file"])).read_text(encoding="utf-8").strip()
        for item in items
        if item.get("ref_text_file")
    }
    ref_texts.discard("")
    if not ref_audios and not ref_texts:
        return None, None
    if len(ref_audios) != 1 or len(ref_texts) != 1:
        return None, None
    shared_ref_audio = next(iter(ref_audios))
    shared_ref_text = next(iter(ref_texts))
    return shared_ref_audio, shared_ref_text


def _synthesize_serial_item(model: Any, item: dict[str, Any], generate_audio: Any, prefix: str) -> None:
    text = _read_text_file(item)
    ref_text = None
    if item.get("ref_text_file"):
        ref_text = Path(str(item["ref_text_file"])).read_text(encoding="utf-8").strip() or None

    output = Path(str(item["output"]))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="salient-qwen-") as tmp_name:
        tmp_dir = Path(tmp_name)
        file_prefix = f"qwen_chunk_{prefix}".replace("/", "_")
        _quiet_call(
            generate_audio,
            text=text,
            model=model,
            voice=str(item.get("speaker", "")),
            speed=1.0,
            lang_code=str(item.get("language", "auto")) or "auto",
            ref_audio=item.get("ref_audio") or None,
            ref_text=ref_text,
            output_path=str(tmp_dir),
            file_prefix=file_prefix,
            audio_format="wav",
            join_audio=True,
            play=False,
            verbose=False,
            max_tokens=DEFAULT_MAX_TOKENS,
            temperature=0.5,
            top_p=0.9,
            top_k=50,
            repetition_penalty=1.1,
        )
        generated = _detect_output(tmp_dir, file_prefix)
        shutil.move(str(generated), str(output))


def _read_text_file(item: dict[str, Any]) -> str:
    text = Path(str(item["text_file"])).read_text(encoding="utf-8").strip()
    if not text:
        raise ValueError("empty text")
    return text


def _detect_output(directory: Path, file_prefix: str) -> Path:
    expected = directory / f"{file_prefix}.wav"
    if expected.exists():
        return expected
    matches = sorted(directory.glob(f"{file_prefix}*.wav"))
    if not matches:
        raise RuntimeError("Qwen synthesis did not produce a WAV file.")
    return max(matches, key=lambda path: path.stat().st_mtime)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="qwen_tts_helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor_parser = subparsers.add_parser("doctor")
    doctor_parser.set_defaults(func=doctor)

    synth_parser = subparsers.add_parser("synthesize")
    synth_parser.add_argument("--model", required=True)
    synth_parser.add_argument("--speaker", required=True)
    synth_parser.add_argument("--language", required=True)
    synth_parser.add_argument("--text-file", required=True)
    synth_parser.add_argument("--output", required=True)
    synth_parser.add_argument("--ref-audio")
    synth_parser.add_argument("--ref-text-file")
    synth_parser.set_defaults(func=synthesize)

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--model", required=True)
    serve_parser.set_defaults(func=serve)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:
        _json({"ok": False, "error": _redacted_error(exc)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
