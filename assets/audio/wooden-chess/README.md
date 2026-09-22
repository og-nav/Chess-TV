# Wooden chess sounds

Recorded by **el_boss**, published on Freesound on 25 November 2020. Both source
pages explicitly label these recordings **Creative Commons 0 (CC0 1.0)**.
Retrieved 21 September 2026 from the public high-quality MP3 previews; these are
the preview encodings, not an authenticated download of the original upload.

| File | Source | Download |
| --- | --- | --- |
| `piece-placement.mp3` | [Piece Placement](https://freesound.org/people/el_boss/sounds/546119/) | [HQ preview](https://cdn.freesound.org/previews/546/546119_9129912-hq.mp3) |
| `piece-capture.mp3` | [Piece Capture](https://freesound.org/people/el_boss/sounds/546120/) | [HQ preview](https://cdn.freesound.org/previews/546/546120_9129912-hq.mp3) |

License: <https://creativecommons.org/publicdomain/zero/1.0/>
Legal text: <https://creativecommons.org/publicdomain/zero/1.0/legalcode>

`python3 scripts/make-sounds.py` decodes these with ffmpeg, removes low rumble and
excess high frequencies, trims padding, fades the edges, and balances short-event
energy with a -6 dBFS peak ceiling. Output is 44.1 kHz, 16-bit mono PCM WAV.
Move uses Piece Placement; capture uses Piece Capture; check uses Piece Placement
with a quieter second tap 105 ms later. No tonal alert is layered onto check.
The existing original game-over chime is regenerated without changes.

Source SHA-256 checksums are recorded in `SHA256SUMS`.
