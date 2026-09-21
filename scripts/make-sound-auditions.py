#!/usr/bin/env python3
"""Original sound candidates; never writes to the shipping app's Resources directory.

Run with Python's standard library. Each set has four 44.1 kHz / 16-bit mono WAVs,
a four-event audition, and a repeated-move loop. No recordings or third-party samples.
"""
from pathlib import Path
import json
import math
import random
import struct
import wave

RATE = 44100
ROOT = Path(__file__).resolve().parents[1] / "design" / "audio-auditions"


def silence(seconds):
    return [0.0] * round(seconds * RATE)


def add(destination, sound, offset=0.0, gain=1.0):
    first = round(offset * RATE)
    for i, value in enumerate(sound):
        if first + i < len(destination):
            destination[first + i] += value * gain


def bandpass(samples, frequency, q):
    """Damped modal body excited by noise, rather than a pure low sine beep."""
    omega = 2 * math.pi * frequency / RATE
    alpha = math.sin(omega) / (2 * q)
    b0, b2 = alpha / (1 + alpha), -alpha / (1 + alpha)
    a1, a2 = -2 * math.cos(omega) / (1 + alpha), (1 - alpha) / (1 + alpha)
    x1 = x2 = y1 = y2 = 0.0
    output = []
    for x in samples:
        y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        output.append(y)
        x2, x1, y2, y1 = x1, x, y1, y
    return output


def impact(seed, duration, modes, damping, click, softness=0.00035):
    rng = random.Random(seed)
    count = round(duration * RATE)
    excitation = []
    for i in range(count):
        t = i / RATE
        excitation.append(rng.uniform(-1, 1) * math.exp(-t / damping) * (1 - math.exp(-t / softness)))
    output = [click * value for value in excitation]
    for frequency, q, gain in modes:
        for i, value in enumerate(bandpass(excitation, frequency, q)):
            output[i] += value * gain
    return output


def mallet(frequency, duration, decay, gain=1.0):
    result = []
    for i in range(round(duration * RATE)):
        t = i / RATE
        envelope = (1 - math.exp(-t / 0.003)) * math.exp(-t / decay)
        phase = 2 * math.pi * frequency * t
        result.append(gain * envelope * (math.sin(phase) + 0.10 * math.sin(phase * 2.71) * math.exp(-t / 0.025)))
    return result


def finish(samples, target=0.043, ceiling=0.53):
    # Match energy in a 200 ms window, with headroom for the fastest transients.
    mean = sum(samples) / len(samples)
    samples = [x - mean for x in samples]
    tail = min(round(RATE * 0.008), len(samples))
    for i in range(tail):
        samples[-tail + i] *= 0.5 + 0.5 * math.cos(math.pi * i / (tail - 1))
    head = min(round(RATE * 0.00025), len(samples))
    for i in range(head):
        samples[i] *= i / max(1, head - 1)
    rms = math.sqrt(sum(x * x for x in samples[:round(RATE * .2)]) / (RATE * .2))
    gain = min(target / max(1e-9, rms), ceiling / max(1e-9, max(map(abs, samples))))
    return [x * gain for x in samples]


def wooden():
    modes = [(570, 1.3, 1.0), (1170, 2.5, 0.72), (2230, 2.0, 0.36), (3460, 1.6, 0.10)]
    def hit(seed, weight=1):
        return impact(seed, .105, [(f / weight, q, g) for f, q, g in modes], .009 * weight, .12, .0004)
    move = hit(10)
    capture = silence(.18)
    add(capture, hit(11, .92), gain=.52)
    add(capture, hit(12, 1.17), .035)
    check = silence(.24)
    add(check, hit(13, .83), gain=.72)
    add(check, hit(14, .83), .082, .72)
    end = silence(.40)
    for start, weight, gain in [(0, .85, .70), (.11, 1.0, .64), (.23, 1.28, .58)]:
        add(end, hit(15, weight), start, gain)
    return dict(move=move, capture=capture, check=check, gameover=end)


def felt():
    modes = [(760, 1.2, 1.0), (1620, 1.3, .40), (2850, 1.1, .16)]
    def hit(seed, weight=1):
        result = impact(seed, .12, [(f / weight, q, g) for f, q, g in modes], .006 * weight, .035, .0008)
        add(result, mallet(330 / weight, .06, .010, .06))
        return result
    move = hit(20)
    capture = silence(.17)
    add(capture, hit(21, .90), gain=.30)
    add(capture, hit(22, 1.20), .025)
    check = silence(.28)
    add(check, hit(23, .85), gain=.62)
    add(check, mallet(784, .20, .036, .13), .018)
    end = silence(.53)
    for start, freq, gain in [(0, 659.25, .26), (.105, 523.25, .23), (.23, 392, .19)]:
        add(end, mallet(freq, .30, .068, gain), start)
    return dict(move=move, capture=capture, check=check, gameover=end)


def digital():
    def pluck(frequency, duration=.10):
        result = mallet(frequency, duration, .018)
        add(result, impact(30, duration, [(2100, 1.3, 1)], .002, .04), gain=.08)
        return result
    move = pluck(620)
    capture = silence(.18)
    add(capture, pluck(730), gain=.44)
    add(capture, pluck(465), .032, .84)
    check = silence(.29)
    add(check, mallet(830.6, .25, .052), gain=.68)
    add(check, mallet(1108.7, .19, .037), .06, .42)
    end = silence(.59)
    for start, frequency, gain in [(0, 698.46, .58), (.11, 587.33, .50), (.25, 440, .48)]:
        add(end, mallet(frequency, .34, .085), start, gain)
    return dict(move=move, capture=capture, check=check, gameover=end)


def write(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    assert samples and max(map(abs, samples)) < 1.0
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(b"".join(struct.pack("<h", round(value * 32767)) for value in samples))
    return {"duration": round(len(samples) / RATE, 3), "peak_dbfs": round(20 * math.log10(max(map(abs, samples))), 2)}


def main():
    manifest = {}
    move_comparison = silence(7.2)
    for index, (name, make) in enumerate([("A-wood", wooden), ("B-felt", felt), ("C-digital", digital)]):
        samples = {event: finish(sound, .043 if event in ("move", "capture") else .036) for event, sound in make().items()}
        preview = silence(6.4)
        loop = silence(5.2)
        for start, event in [(.35, "move"), (1.65, "capture"), (3.0, "check"), (4.55, "gameover")]:
            add(preview, samples[event], start)
        for start in [.3, 1.05, 1.8, 2.55, 3.3, 4.05]:
            add(loop, samples["move"], start)
        for event, sound in samples.items():
            manifest[f"{name}/{event}.wav"] = write(ROOT / name / f"{event}.wav", sound)
        write(ROOT / f"{name}-audition.wav", preview)
        write(ROOT / f"{name}-move-loop.wav", loop)
        for start in [.35, 1.1]:
            add(move_comparison, samples["move"], index * 2.2 + start)
    write(ROOT / "move-comparison-A-B-C.wav", move_comparison)
    (ROOT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Wrote three original sets, auditions and move loops to {ROOT}")


if __name__ == "__main__":
    main()
