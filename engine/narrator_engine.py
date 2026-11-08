"""Better Narrator speech engine.

Runs Kokoro on this Mac and streams speech back one segment at a time, with the
start and end time of every written word so the app can highlight it.

Protocol: one JSON object per line.

  stdin  {"cmd": "synth", "job": "<id>", "voice": "af_heart",
          "segments": [{"i": 0, "text": "...", "pause": 0.3}, ...]}
         {"cmd": "focus", "job": "<id>"}     generate this job first
         {"cmd": "cancel", "job": "<id>"}
         {"cmd": "quit"}
  stdout {"type": "ready", "voices": [...]}
         {"type": "segment", "job", "i", "sr", "audio": <base64 float32 LE>,
          "words": [[char_start, char_end, start_sec, end_sec], ...],
          "gen_seconds": <float>}
         {"type": "job_done", "job"}
         {"type": "error", "job"?, "i"?, "message"}
"""
from __future__ import annotations

import base64
import json
import os
import re
import sys
import threading
import time
import traceback
from collections import OrderedDict, deque
from pathlib import Path

import numpy as np
import onnxruntime as ort
from kokoro_onnx import Kokoro

SR = 24000
MAX_PHONEMES = 500
WORD_RE = re.compile(r"\S+")
_out_lock = threading.Lock()


def emit(obj: dict) -> None:
    line = json.dumps(obj, separators=(",", ":"))
    with _out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


class Engine:
    def __init__(self, model_dir: Path):
        # One thread per physical core, and idle threads sleep instead of spinning,
        # so the app's window and audio stay smooth while speech is generated.
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = int(os.environ.get("BN_THREADS", "4"))
        opts.add_session_config_entry("session.intra_op.allow_spinning", "0")
        session = ort.InferenceSession(str(model_dir / "kokoro-timestamped.onnx"), sess_options=opts,
                                       providers=["CPUExecutionProvider"])
        self.kokoro = Kokoro.from_session(session, str(model_dir / "voices-v1.0.bin"))
        self.sess = self.kokoro.sess
        self.tok = self.kokoro.tokenizer
        self.input_name = self.sess.get_inputs()[0].name
        self.space_ids = {v for k, v in self.tok.vocab.items() if k == " "}
        self.jobs: "OrderedDict[str, dict]" = OrderedDict()
        self.focus: str | None = None
        self.cv = threading.Condition()
        self.running = True

    # ---------- commands ----------
    def handle(self, msg: dict) -> None:
        cmd = msg.get("cmd")
        with self.cv:
            if cmd == "synth":
                self.jobs[msg["job"]] = {
                    "voice": msg.get("voice", "af_heart"),
                    "segments": deque(msg.get("segments", [])),
                }
                self.focus = msg["job"]
            elif cmd == "focus":
                if msg.get("job") in self.jobs:
                    self.focus = msg["job"]
            elif cmd == "cancel":
                self.jobs.pop(msg.get("job"), None)
                if self.focus == msg.get("job"):
                    self.focus = None
            elif cmd == "quit":
                self.running = False
            self.cv.notify_all()

    def next_work(self):
        with self.cv:
            while self.running:
                order = list(self.jobs.keys())
                if self.focus in self.jobs:
                    order.remove(self.focus)
                    order.insert(0, self.focus)
                for job_id in order:
                    job = self.jobs[job_id]
                    if job["segments"]:
                        return job_id, job["voice"], job["segments"].popleft()
                    self.jobs.pop(job_id)
                    emit({"type": "job_done", "job": job_id})
                self.cv.wait()
            return None

    def run(self) -> None:
        # Warm up so the first real sentence starts quickly.
        try:
            self.synthesize("Ready.", "af_heart")
        except Exception:
            pass
        emit({"type": "ready", "voices": self.kokoro.get_voices()})
        while True:
            work = self.next_work()
            if work is None:
                return
            job_id, voice, seg = work
            t0 = time.time()
            try:
                audio, words = self.synthesize(seg["text"], voice)
            except Exception as e:  # keep going; the app shows a gap instead of stopping
                emit({"type": "error", "job": job_id, "i": seg.get("i"),
                      "message": f"{type(e).__name__}: {e}"})
                audio, words = np.zeros(int(SR * 0.3), dtype=np.float32), []
            pause = float(seg.get("pause", 0.0))
            if pause > 0:
                audio = np.concatenate([audio, np.zeros(int(SR * pause), dtype=np.float32)])
            with self.cv:
                if job_id not in self.jobs:
                    continue  # cancelled while we were working
            emit({
                "type": "segment", "job": job_id, "i": seg.get("i"), "sr": SR,
                "audio": base64.b64encode(audio.astype("<f4").tobytes()).decode("ascii"),
                "words": words, "gen_seconds": round(time.time() - t0, 3),
            })

    # ---------- speech ----------
    def lang_for(self, voice: str) -> str:
        return "en-gb" if voice.startswith("b") else "en-us"

    def synthesize(self, text: str, voice: str):
        """Return (audio, words) where words are [char_start, char_end, start, end]."""
        text = text.strip()
        if not WORD_RE.search(text):
            return np.zeros(int(SR * 0.2), dtype=np.float32), []
        lang = self.lang_for(voice)
        phonemes = self.tok.phonemize(text, lang=lang)
        if len(phonemes) > MAX_PHONEMES:
            return self._split_and_synthesize(text, voice)
        tokens = self.tok.tokenize(phonemes)
        if not tokens:
            return np.zeros(int(SR * 0.2), dtype=np.float32), []
        style = self.kokoro.voices[voice][min(len(tokens), 509)]
        out = self.sess.run(None, {
            self.input_name: np.array([[0, *tokens, 0]], dtype=np.int64),
            "style": np.asarray(style, dtype=np.float32),
            "speed": np.array([1.0], dtype=np.float32),
        })
        audio = np.asarray(out[0], dtype=np.float32).ravel()
        durations = np.asarray(out[1], dtype=np.float64).ravel()
        spoken = self._spoken_word_times(tokens, durations, len(audio))
        words = self._align(text, spoken, lang)
        return audio, words

    def _split_and_synthesize(self, text: str, voice: str):
        mid = len(text) // 2
        cut = max(text.rfind(", ", 0, mid), text.rfind("; ", 0, mid))
        if cut < len(text) // 4:
            cut = text.rfind(" ", 0, mid)
        if cut <= 0:
            cut = mid
        left, right = text[:cut + 1], text[cut + 1:]
        a1, w1 = self.synthesize(left, voice)
        a2, w2 = self.synthesize(right, voice)
        lead = len(left) - len(left.lstrip())
        shift_c = len(text[:cut + 1]) + (len(right) - len(right.lstrip()))
        offset = len(a1) / SR
        words = [[s + lead, e + lead, t0, t1] for s, e, t0, t1 in w1]
        words += [[s + shift_c, e + shift_c, t0 + offset, t1 + offset] for s, e, t0, t1 in w2]
        return np.concatenate([a1, a2]), words

    def _spoken_word_times(self, tokens, durations, n_samples):
        frames = durations
        total = frames.sum()
        if total <= 0:
            return []
        spf = (n_samples / SR) / total
        t = frames[0] * spf  # leading pad token
        spans, start, inside = [], None, False
        for i, tid in enumerate(tokens):
            d = frames[i + 1] * spf if i + 1 < len(frames) else 0
            if tid in self.space_ids:
                if inside:
                    spans.append([start, t])
                    inside = False
            else:
                if not inside:
                    start, inside = t, True
            t += d
        if inside:
            spans.append([start, t])
        return spans

    def _align(self, text, spoken, lang):
        written = [(m.start(), m.end()) for m in WORD_RE.finditer(text)]
        if not written or not spoken:
            return []
        if len(written) == len(spoken):
            groups = [[i] for i in range(len(spoken))]
        else:
            counts = []
            for s, e in written:
                try:
                    ph = self.tok.phonemize(text[s:e], lang=lang)
                    counts.append(len(ph.split()))
                except Exception:
                    counts.append(1)
            if sum(counts) == len(spoken):
                groups, j = [], 0
                for c in counts:
                    groups.append(list(range(j, j + c)))
                    j += c
            else:
                # Fall back to spreading spoken words across written words by length.
                lengths = np.array([e - s for s, e in written], dtype=float)
                bounds = np.cumsum(lengths) / lengths.sum()
                groups = [[] for _ in written]
                for j in range(len(spoken)):
                    pos = (j + 0.5) / len(spoken)
                    k = int(np.searchsorted(bounds, pos))
                    groups[min(k, len(written) - 1)].append(j)
        words, last_end = [], 0.0
        for (s, e), g in zip(written, groups):
            if g:
                t0, t1 = spoken[g[0]][0], spoken[g[-1]][1]
                last_end = t1
            else:
                t0 = t1 = last_end
            # The app counts characters in UTF-16 (emoji count as two).
            words.append([len(text[:s].encode("utf-16-le")) // 2, len(text[:e].encode("utf-16-le")) // 2,
                          round(float(t0), 3), round(float(t1), 3)])
        return words


def main() -> None:
    model_dir = Path(sys.argv[1])
    try:
        engine = Engine(model_dir)
    except Exception as e:
        emit({"type": "error", "message": f"Could not load Kokoro: {e}"})
        raise

    def reader():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                engine.handle(json.loads(line))
            except Exception as e:
                emit({"type": "error", "message": f"bad command: {e}"})
        engine.handle({"cmd": "quit"})  # app closed our stdin

    threading.Thread(target=reader, daemon=True).start()
    try:
        engine.run()
    except Exception:
        emit({"type": "error", "message": traceback.format_exc()})


if __name__ == "__main__":
    main()
