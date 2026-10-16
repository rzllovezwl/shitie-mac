"""Generate the original, short copy chime bundled with ClipHoook."""

import math
import struct
import wave
from pathlib import Path


SAMPLE_RATE = 44_100
DURATION = 0.22
OUTPUT = Path(__file__).resolve().parents[1] / "ClipboardShelf/Resources/CopyChime.wav"


def bell(elapsed: float, fundamental: float) -> float:
    if elapsed < 0:
        return 0.0
    attack = min(1.0, elapsed / 0.0018)
    decay = math.exp(-elapsed / 0.043)
    phase = 2 * math.pi * fundamental * elapsed
    return attack * decay * (
        math.sin(phase)
        + 0.36 * math.sin(phase * 1.91)
        + 0.13 * math.sin(phase * 2.87)
    )


samples = []
for index in range(round(SAMPLE_RATE * DURATION)):
    time = index / SAMPLE_RATE
    value = bell(time, 1280) + 0.31 * bell(time - 0.027, 1760)
    fade_out = min(1.0, (DURATION - time) / 0.012)
    samples.append(value * max(0.0, fade_out))

peak = max(abs(value) for value in samples)
pcm = b"".join(struct.pack("<h", round(value / peak * 0.72 * 32767)) for value in samples)
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(OUTPUT), "wb") as sound:
    sound.setnchannels(1)
    sound.setsampwidth(2)
    sound.setframerate(SAMPLE_RATE)
    sound.writeframes(pcm)

print(OUTPUT)
