#!/usr/bin/env python3
"""Generates every sound the app plays, into Apps/ChessTV/Resources/Sounds/.

    python3 scripts/make-sounds.py

Four files, all original to this project — nothing sampled, recorded or copied from
anywhere else. Each one is 44.1 kHz, 16-bit, mono PCM, synthesized from decaying
sinusoids plus (for the taps) a pinch of resonator-filtered noise from a seeded
generator, so the output is byte-for-byte reproducible on any machine with a Python 3
standard library and nothing else:

    move.wav     105 ms   the selected Wood audition: a dry, textured piece landing
    capture.wav  ~125 ms   the same tap answered by a heavier, lower body
    check.wav    ~250 ms   a two-note chime, A5 then D6, bright but not an alarm
    gameover.wav  600 ms   a slower two-note chime an octave down, E5 then A5

They are meant to carry across a living room on TV speakers and still sit politely in a
phone's earpiece: short, dry, with a few milliseconds of fade at both ends so no file can
start or stop on a step.

Loudness: capture and check retain their original calibration against the previous move
sound; the selected Wood move retains its audition level. The original trio was matched by the energy each one puts
into a fixed 200 ms window, which tracks how loud a short sound actually seems far better
than its peak does, then scaled together so the loudest peak lands at -3 dBFS. gameover
keeps the peak normalization it was born with (-6 dBFS), so the file this script writes is
identical to the one scripts/make-gameover-sound.py used to write.
"""
import math
import importlib.util
import os
import random
import struct
import wave

RATE = 44_100

OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Apps", "ChessTV", "Resources", "Sounds",
)

# --- loudness -----------------------------------------------------------------------

# The taps are matched on energy per 200 ms rather than on peak: a 5 ms transient that
# peaks at 0 dBFS is far quieter to the ear than a 200 ms chime that does.
LOUDNESS_WINDOW = 0.200
PEAK_CEILING = 0.708             # -3 dBFS, the loudest peak allowed among the matched set
# Long enough that no file can begin on a step, short enough that a tap still sounds
# struck rather than faded up; raised-cosine, so even the slope starts at zero.
FADE_IN = 0.0010
FADE_OUT = 0.006                 # every file ramps to true silence before it ends


def loudness(frames: list[float]) -> float:
    """RMS over a fixed window, so a shorter sound reads as the quieter one."""
    window = int(RATE * LOUDNESS_WINDOW)
    energy = sum(value * value for value in frames[:window])
    return math.sqrt(energy / window)


# --- building blocks ----------------------------------------------------------------


def partial(frames: list[float], start: float, frequency: float,
            amplitude: float, decay: float, attack: float = 0.0008) -> None:
    """Add one exponentially decaying sinusoid, in place."""
    first = int(RATE * start)
    step = 2 * math.pi * frequency / RATE
    for index in range(first, len(frames)):
        age = (index - first) / RATE
        envelope = math.exp(-age / decay)
        if envelope < 1e-4:
            break
        if attack > 0:
            envelope *= min(1.0, age / attack)
        frames[index] += amplitude * envelope * math.sin(step * (index - first))


def click(frames: list[float], start: float, frequency: float,
          amplitude: float, decay: float, resonance: float, seed: int) -> None:
    """Add a short noise burst through a two-pole resonator: the knock of wood on wood.

    The noise comes from a seeded Mersenne Twister, so the same bytes come out every run.
    """
    noise = random.Random(seed)
    # Standard two-pole resonator: one pole pair at `frequency`, bandwidth set by `resonance`.
    radius = math.exp(-math.pi * frequency / (resonance * RATE))
    a1 = -2 * radius * math.cos(2 * math.pi * frequency / RATE)
    a2 = radius * radius
    gain = (1 - radius) * math.sqrt(1 - 2 * radius * math.cos(4 * math.pi * frequency / RATE) + a2)
    first = int(RATE * start)
    previous = second_previous = 0.0
    for index in range(first, len(frames)):
        age = (index - first) / RATE
        envelope = math.exp(-age / decay)
        if envelope < 1e-4:
            break
        sample = gain * (noise.random() * 2 - 1) - a1 * previous - a2 * second_previous
        second_previous, previous = previous, sample
        frames[index] += amplitude * envelope * sample


def blank(duration: float) -> list[float]:
    return [0.0] * int(RATE * duration)


# --- the sounds ---------------------------------------------------------------------


def make_move() -> list[float]:
    """The exact Wood move audition selected by the owner."""
    path = os.path.join(os.path.dirname(__file__), "make-sound-auditions.py")
    spec = importlib.util.spec_from_file_location("sound_auditions", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.finish(module.wooden()["move"])



def _make_reference_move() -> list[float]:
    """A knuckle-sized piece set down on a board: thump, faint click, gone."""
    frames = blank(0.075)
    # A slightly inharmonic stack is what keeps it wooden instead of a tuned beep.
    partial(frames, 0.000, 207.0, 1.000, 0.0185)
    partial(frames, 0.000, 421.0, 0.400, 0.0115)
    partial(frames, 0.000, 806.0, 0.150, 0.0060)
    click(frames, 0.000, 2_450.0, 0.170, 0.0035, resonance=1.6, seed=1)
    return frames


def make_capture() -> list[float]:
    """The same tap, with a second heavier one landing under it 35 ms later."""
    frames = blank(0.125)
    partial(frames, 0.000, 231.0, 0.780, 0.0150)
    partial(frames, 0.000, 455.0, 0.320, 0.0095)
    click(frames, 0.000, 2_650.0, 0.150, 0.0030, resonance=1.6, seed=2)
    # The lower body: bigger piece, more wood, a longer ring.
    partial(frames, 0.035, 138.0, 1.000, 0.0330)
    partial(frames, 0.035, 279.0, 0.420, 0.0210)
    partial(frames, 0.035, 534.0, 0.140, 0.0090)
    click(frames, 0.035, 1_850.0, 0.130, 0.0045, resonance=1.4, seed=3)
    return frames


def make_check() -> list[float]:
    """A5 then D6, a rising fourth: the same interval gameover uses, an octave up and
    four times faster, so the two read as one family without being mistaken for each
    other. Bell-ish partials and a soft attack keep it a chime, not a buzzer."""
    frames = blank(0.250)
    for start, frequency in ((0.000, 880.000), (0.085, 1_174.659)):
        partial(frames, start, frequency, 1.000, 0.0720, attack=0.004)
        partial(frames, start, frequency * 2, 0.190, 0.0450, attack=0.004)
        partial(frames, start, frequency * 3, 0.055, 0.0260, attack=0.004)
    return frames


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


# --- writing --------------------------------------------------------------------------


def fade_edges(frames: list[float]) -> None:
    count = len(frames)
    head = int(RATE * FADE_IN)
    for index in range(min(head, count)):
        frames[index] *= 0.5 - 0.5 * math.cos(math.pi * index / max(1, head - 1))
    tail = int(RATE * FADE_OUT)
    for index in range(max(0, count - tail), count):
        frames[index] *= (count - 1 - index) / max(1, tail - 1)


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
    # Keep the original calibration sound here so capture/check retain their exact bytes.
    matched = {"move.wav": _make_reference_move(), "capture.wav": make_capture(), "check.wav": make_check()}
    for frames in matched.values():
        fade_edges(frames)
    # One scale for all three: match them to the loudest of the set, then pull the group
    # down until its highest peak sits at the ceiling. Relative balance survives both steps.
    reference = max(loudness(frames) for frames in matched.values())
    for frames in matched.values():
        scale = reference / (loudness(frames) or 1.0)
        for index, value in enumerate(frames):
            frames[index] = value * scale
    headroom = PEAK_CEILING / max(max(abs(value) for value in frames) for frames in matched.values())
    for frames in matched.values():
        for index, value in enumerate(frames):
            frames[index] = value * headroom

    # gameover is left out of both the fades and the loudness match: it carries its own
    # 8 ms ramp to silence and its own peak normalization, and this file has to come out
    # exactly as it did before.
    everything = dict(matched)
    everything["move.wav"] = make_move()
    everything["gameover.wav"] = make_gameover()
    for name, frames in everything.items():
        path, seconds, peak_db = write(name, frames)
        print(f"wrote {path} ({seconds * 1000:.0f} ms, peak {peak_db:+.1f} dBFS)")


if __name__ == "__main__":
    main()
