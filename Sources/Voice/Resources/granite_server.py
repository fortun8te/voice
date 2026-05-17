#!/usr/bin/env python3
"""
VOICE — IBM Granite 4.0 1B Speech transcription server.

Persistent subprocess: loads the model once, handles JSON requests via stdin/stdout.

Protocol (one JSON object per line, newline-terminated):
  Startup:   {"status": "ready"} | {"status": "unavailable", "reason": "..."}
  Request:   {"path": "/abs/path/to/audio.caf"}
  Response:  {"text": "..."} | {"error": "..."}
"""
import sys
import json
import os


def _load_mlx_audio():
    """Try mlx-audio backend (Metal-accelerated, preferred).
    API (mlx-audio >= 0.4.0):
        from mlx_audio.stt import load_model
        from mlx_audio.stt.generate import generate_transcription
        model = load_model("mlx-community/granite-4.0-1b-speech-5bit")
        result = generate_transcription(model=model, audio=audio_path, format="txt")

    Model priority:
      1. mlx-community/granite-4.0-1b-speech-5bit  — quantized MLX weights, avoids
         the conv-layer shape mismatch seen with raw HF weights
      2. mlx-community/granite-4.0-1b-speech-8bit  — higher quality fallback
      3. ibm-granite/granite-4.0-1b-speech          — original bf16 (may hit conv bug)
    """
    try:
        from mlx_audio.stt import load_model
        from mlx_audio.stt.generate import generate_transcription
        import tempfile, os as _os

        # Try quantized MLX variants first — they avoid the conv-layer shape bug
        # seen with the raw HuggingFace bf16 weights.
        _model_candidates = [
            "mlx-community/granite-4.0-1b-speech-5bit",
            "mlx-community/granite-4.0-1b-speech-8bit",
            "ibm-granite/granite-4.0-1b-speech",
        ]
        model = None
        _load_err = None
        for _mid in _model_candidates:
            try:
                print(f"[granite_server] trying {_mid} ...", file=sys.stderr, flush=True)
                model = load_model(_mid)
                print(f"[granite_server] loaded {_mid}", file=sys.stderr, flush=True)
                break
            except Exception as _e:
                print(f"[granite_server] {_mid} failed: {_e}", file=sys.stderr, flush=True)
                _load_err = _e
        if model is None:
            raise RuntimeError(f"all model candidates failed; last error: {_load_err}")

        # CAF isn't supported by mlx-audio's audio loader — convert via
        # soundfile (libsndfile supports CAF read + WAV write).
        try:
            import soundfile as _sf
        except ImportError:
            _sf = None

        def _to_wav_if_needed(src):
            """Always re-encode to 16kHz mono PCM_16 WAV — Granite is strict
            about its input shape (model expects 16kHz mono mel features)."""
            if _sf is None:
                raise RuntimeError("soundfile not installed (pip install soundfile)")
            data, sr = _sf.read(src)
            # Downmix to mono if multi-channel.
            if hasattr(data, "ndim") and data.ndim > 1:
                import numpy as _np
                data = _np.mean(data, axis=1)
            # Resample to 16kHz if needed (Granite's training sample rate).
            if sr != 16000:
                try:
                    import librosa as _lr
                    import numpy as _np
                    data = _lr.resample(_np.asarray(data, dtype="float32"), orig_sr=sr, target_sr=16000)
                    sr = 16000
                except ImportError:
                    pass  # write at native sample rate, let Granite try
            tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            tmp.close()
            _sf.write(tmp.name, data, sr, subtype="PCM_16")
            return tmp.name, tmp.name  # second value = cleanup path

        def fn(path):
            wav_path, cleanup = _to_wav_if_needed(path)
            try:
                with tempfile.TemporaryDirectory() as tmpdir:
                    out_base = _os.path.join(tmpdir, "transcript")
                    result = generate_transcription(
                        model=model,
                        audio=wav_path,
                        output_path=out_base,
                        format="txt",
                        verbose=False,
                    )
                    # Try to extract from return value first.
                    if isinstance(result, dict):
                        if "text" in result:
                            return result["text"]
                        if "transcription" in result:
                            return result["transcription"]
                    if isinstance(result, str):
                        return result
                    # Fallback: read the written .txt file.
                    txt_path = out_base + ".txt"
                    text_out = ""
                    if _os.path.exists(txt_path):
                        with open(txt_path, "r") as f:
                            text_out = f.read()
                    else:
                        text_out = str(result) if result is not None else ""
                    return text_out
            finally:
                # Clean up temp WAV from format conversion even on crash/exception.
                if cleanup and _os.path.exists(cleanup):
                    try: _os.remove(cleanup)
                    except OSError: pass

        return fn, None
    except ImportError as e:
        return None, f"mlx_audio not installed: {e}"
    except Exception as e:
        return None, f"mlx_audio load failed: {e}"


def main():
    # mlx-audio only — transformers fallback removed (too slow for dictation, ~5-15s/call).
    transcribe, load_error = _load_mlx_audio()

    if transcribe is None:
        print(json.dumps({"status": "unavailable", "reason": load_error}), flush=True)
        # Keep stdin open so the Swift subprocess manager doesn't see EOF.
        for _ in sys.stdin:
            print(json.dumps({"error": "model unavailable"}), flush=True)
        return

    print(json.dumps({"status": "ready"}), flush=True)

    def _watch_parent():
        """Exit if our parent process dies — prevents orphaning when Voice crashes."""
        import os, time
        parent = os.getppid()
        while True:
            time.sleep(2)
            try:
                # On macOS, if parent dies we get reparented to launchd (PID 1)
                if os.getppid() != parent:
                    print(f"[granite_server] parent {parent} died, exiting", file=sys.stderr, flush=True)
                    os._exit(0)
            except Exception:
                pass

    import threading
    threading.Thread(target=_watch_parent, daemon=True).start()

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
        except json.JSONDecodeError as e:
            print(json.dumps({"error": f"bad JSON: {e}"}), flush=True)
            continue

        path = req.get("path", "")
        if not path or not os.path.exists(path):
            print(json.dumps({"error": f"file not found: {path}"}), flush=True)
            continue

        try:
            text = transcribe(path)
            print(json.dumps({"text": text.strip()}), flush=True)
        except Exception as e:
            print(json.dumps({"error": str(e)}), flush=True)


if __name__ == "__main__":
    main()
