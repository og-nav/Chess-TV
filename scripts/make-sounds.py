#!/usr/bin/env python3
"""Build the app's six sound sets plus the original shared game-over chime.

Requires ffmpeg on PATH. Sources and licensing: assets/audio/wooden-chess/README.md.
Output: 44.1 kHz, 16-bit mono WAV. Check is a restrained double wooden tap.
The game-over chime is preserved byte for byte from the original generator.
"""
import argparse
import base64
import math
import os
from pathlib import Path
import struct
import subprocess
import shutil
import sys
import wave

RATE = 44_100
ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "Apps/ChessTV/Resources/Sounds"
SOURCE_DIR = ROOT / "assets/audio/wooden-chess"


def recording(name: str) -> list[float]:
    pcm = subprocess.run([
        "ffmpeg", "-v", "error", "-i", str(SOURCE_DIR / name),
        "-af", "highpass=f=65,lowpass=f=7000", "-ac", "1", "-ar", str(RATE),
        "-f", "f32le", "pipe:1",
    ], check=True, capture_output=True).stdout
    frames = list(struct.unpack(f"<{len(pcm) // 4}f", pcm))
    # Remove codec padding, retaining the natural decay and a short quiet tail.
    threshold = max(map(abs, frames)) * 0.003
    active = [i for i, sample in enumerate(frames) if abs(sample) > threshold]
    first = max(0, active[0] - int(RATE * 0.002))
    last = min(len(frames), active[-1] + int(RATE * 0.010))
    frames = frames[first:last]
    for i in range(min(len(frames), int(RATE * 0.001))):
        frames[i] *= i / max(1, int(RATE * 0.001) - 1)
    tail = min(len(frames), int(RATE * 0.008))
    for i in range(tail):
        frames[len(frames) - tail + i] *= (tail - 1 - i) / max(1, tail - 1)
    return frames


def balance(frames: list[float], target: float) -> list[float]:
    # Match short-event energy, with ample peak headroom for TV speakers.
    rms = math.sqrt(sum(x * x for x in frames) / (RATE * 0.2))
    scale = min(target / rms, 10 ** (-6 / 20) / max(map(abs, frames)))
    return [x * scale for x in frames]


def wooden_sounds() -> dict[str, list[float]]:
    move = recording("piece-placement.mp3")
    capture = recording("piece-capture.mp3")
    offset = int(RATE * 0.105)
    check = [0.0] * (offset + len(move))
    for i, sample in enumerate(move):
        check[i] += sample
        check[offset + i] += sample * 0.40
    return {
        "move.wav": balance(move, 0.045),
        "capture.wav": balance(capture, 0.055),
        "check.wav": balance(check, 0.050),
    }


# gameover keeps its own numbers, verbatim from the script it replaces.
GAMEOVER_DURATION = 0.6
GAMEOVER_PEAK = 0.5              # about -6 dBFS
GAMEOVER_ATTACK = 0.006          # a soft edge, not a click
GAMEOVER_DECAY = 0.22            # exponential tail, in seconds
# (start second, frequency); the second note lands while the first is still ringing.
GAMEOVER_NOTES = [(0.00, 659.255), (0.18, 880.000)]
# A little second harmonic keeps it from sounding like a test tone.
GAMEOVER_HARMONIC = 0.22


def make_gameover() -> list[float]:
    """E5 then A5 for the moment a game ends: long enough to notice from a sofa, quiet
    and quick enough not to talk over the next game. Peak-normalized to -6 dBFS here,
    not loudness-matched with the rest, so the sound is unchanged."""
    def envelope(t: float) -> float:
        if t < 0:
            return 0.0
        attack = min(1.0, t / GAMEOVER_ATTACK) if GAMEOVER_ATTACK > 0 else 1.0
        return attack * math.exp(-t / GAMEOVER_DECAY)

    def sample(t: float) -> float:
        value = 0.0
        for start, frequency in GAMEOVER_NOTES:
            age = t - start
            if age < 0:
                continue
            phase = 2 * math.pi * frequency * age
            value += envelope(age) * (math.sin(phase) + GAMEOVER_HARMONIC * math.sin(2 * phase))
        return value

    count = int(RATE * GAMEOVER_DURATION)
    frames = [sample(index / RATE) for index in range(count)]
    # The last 8 ms ramp to silence so the file cannot end on a step.
    tail = int(RATE * 0.008)
    for index in range(count - tail, count):
        frames[index] *= (count - 1 - index) / max(1, tail - 1)
    loudest = max(abs(value) for value in frames) or 1.0
    return [value * GAMEOVER_PEAK / loudest for value in frames]


def write(name: str, frames: list[float]) -> tuple[str, float, float]:
    packed = b"".join(
        struct.pack("<h", max(-32_768, min(32_767, int(round(value * 32_767)))))
        for value in frames
    )
    path = os.path.join(OUTPUT_DIR, name)
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(packed)
    peak = max(abs(value) for value in frames) or 1e-9
    return path, len(frames) / RATE, 20 * math.log10(peak)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", action="store_true", help="Also write a listening preview under design/audio-auditions")
    args = parser.parse_args()
    sounds = wooden_sounds()
    sounds["gameover.wav"] = make_gameover()
    for name, frames in sounds.items():
        path, seconds, peak_db = write(name, frames)
        print(f"wrote {path} ({seconds * 1000:.0f} ms, peak {peak_db:+.1f} dBFS)")
    # The gallery is also the single recipe for the six auditioned, level-matched sets.
    # Unique flat names survive Xcode's resource copying on both iOS and tvOS.
    subprocess.run([sys.executable, str(ROOT / "scripts/make-sound-gallery.py")], check=True)
    for source in sorted((ROOT / "design/audio-auditions/comparison").glob("*/*.wav")):
        shutil.copyfile(source, OUTPUT_DIR / f"sound-{source.parent.name}-{source.name}")
    licences = ROOT / "assets/Licenses"
    original = ROOT / "design/audio-auditions/sources/lichess"
    shutil.copyfile(original / "LICENSE", licences / "AGPL-3.0.txt")
    shutil.copyfile(original / "COPYING.md", licences / "Lichess-Sounds-COPYING.txt")
    if args.preview:
        preview = ROOT / "design/audio-auditions"
        preview.mkdir(parents=True, exist_ok=True)
        sequence = [(0.35, "move.wav"), (1.5, "capture.wav"), (2.7, "check.wav")]
        sequence += [(4.0 + i * 0.6, "move.wav") for i in range(6)]
        frames = [0.0] * (RATE * 8)
        for start, name in sequence:
            for i, sample in enumerate(sounds[name]):
                frames[int(start * RATE) + i] += sample
        with wave.open(str(preview / "recorded-wood-preview.wav"), "wb") as output:
            output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
            output.writeframes(b"".join(struct.pack("<h", round(x * 32767)) for x in frames))
        cards = []
        for name, description in [
            ("move", "A single wooden piece landing."),
            ("capture", "A fuller wooden capture."),
            ("check", "A landing followed by a quieter wooden tap."),
        ]:
            encoded = base64.b64encode((OUTPUT_DIR / f"{name}.wav").read_bytes()).decode()
            cards.append(f'<article><h2>{name.title()}</h2><p>{description}</p>'
                         f'<audio controls preload="auto" src="data:audio/wav;base64,{encoded}"></audio></article>')
        html = '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Chess TV · Wooden sounds</title><style>
body{margin:48px auto;padding:0 24px;max-width:760px;background:#151914;color:#eeeae0;font:17px/1.55 system-ui}
h1{font-size:38px;line-height:1.1}h2{margin:0 0 8px;font-size:22px}p{color:#b8bdb1}
article{padding:24px;background:#232a20;border:1px solid #46503e;border-radius:16px;margin:16px 0}
audio{width:100%;margin:8px 0}a{color:#cbd7a6}small{color:#b8bdb1}</style>
<h1>Wooden chess sounds</h1><p>Real chess-piece recordings, balanced for repeated listening.</p>
''' + "".join(cards) + '''<article><h2>Sequence &amp; repetition</h2>
<p>Move → capture → check → six ordinary moves.</p>
<audio controls src="recorded-wood-preview.wav"></audio></article>
<small>Recordings by <a href="https://freesound.org/people/el_boss/packs/30764/">el_boss</a>, CC0.
Trimmed, filtered, and balanced for Chess TV. Check adds a quieter second tap. Game-over chime is unchanged.</small></html>'''
        (preview / "recorded-wood.html").write_text(html)


if __name__ == "__main__":
    main()
