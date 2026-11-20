#!/usr/bin/env python3
"""Write Gem Grove's three sound effects as small WAV files. No samples, just
sine and noise, so the demo carries no audio it did not make itself."""
import math, random, struct, wave, pathlib

RATE = 22050
OUT = pathlib.Path(__file__).parent / "src" / "audio"


def write(name, samples):
    with wave.open(str(OUT / name), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 30000)) for s in samples))


def tone(freqs, seconds, volume=0.5):
    """A glide through `freqs`, with a quick attack and a fade to silence."""
    n = int(RATE * seconds)
    out, phase = [], 0.0
    for i in range(n):
        t = i / n
        at = t * (len(freqs) - 1)
        lo = int(at)
        hi = min(lo + 1, len(freqs) - 1)
        freq = freqs[lo] + (freqs[hi] - freqs[lo]) * (at - lo)
        phase += 2 * math.pi * freq / RATE
        envelope = min(1.0, i / 60) * (1 - t) ** 1.5
        out.append((math.sin(phase) + 0.3 * math.sin(2 * phase)) * envelope * volume)
    return out


random.seed(3)
write("pickup.wav", tone([880, 1320], 0.09) + tone([1320, 1760], 0.16))
thud = tone([220, 70], 0.28, 0.7)
write("hit.wav", [s + random.uniform(-1, 1) * 0.35 * (1 - i / len(thud)) ** 3 for i, s in enumerate(thud)])
write("over.wav", tone([520, 390], 0.2) + tone([390, 290], 0.2) + tone([290, 150], 0.5))
