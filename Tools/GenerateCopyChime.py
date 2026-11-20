"""Generate the short copy sounds bundled with ClipHoook."""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path
from typing import Callable


SAMPLE_RATE = 44_100
OUTPUT = Path(__file__).resolve().parents[1] / "ClipboardShelf/Resources"


def envelope(elapsed: float, attack: float, decay: float) -> float:
    if elapsed < 0:
        return 0.0
    return min(1.0, elapsed / attack) * math.exp(-elapsed / decay)


def resonance(elapsed: float, frequency: float, decay: float) -> float:
    return envelope(elapsed, 0.0008, decay) * math.sin(math.tau * frequency * elapsed)


def bell(elapsed: float, fundamental: float) -> float:
    phase = math.tau * fundamental * elapsed
    return envelope(elapsed, 0.0018, 0.043) * (
        math.sin(phase)
        + 0.36 * math.sin(phase * 1.91)
        + 0.13 * math.sin(phase * 2.87)
    )


def band_noise(samples: int, low: float, high: float, seed: int) -> list[float]:
    random_source = random.Random(seed)
    lower = upper = 0.0
    low_step = -math.expm1(-math.tau * low / SAMPLE_RATE)
    high_step = -math.expm1(-math.tau * high / SAMPLE_RATE)
    values = []
    for _ in range(samples):
        white = random_source.uniform(-1, 1)
        lower += low_step * (white - lower)
        upper += high_step * (white - upper)
        values.append(upper - lower)
    return values


def shutter(time: float, noise: float) -> float:
    def snap(elapsed: float, body: float, brightness: float) -> float:
        return (
            1.8 * noise * envelope(elapsed, 0.0004, 0.007)
            + 0.32 * resonance(elapsed, body, 0.019)
            + 0.30 * resonance(elapsed, brightness, 0.010)
            + 0.11 * resonance(elapsed - 0.004, 2750, 0.005)
        )

    return snap(time - 0.004, 660, 1620) + 0.76 * snap(time - 0.064, 510, 1310)


def soft_click(time: float, noise: float) -> float:
    return (
        1.1 * noise * envelope(time, 0.0012, 0.008)
        + 0.49 * resonance(time, 340, 0.013)
        + 0.24 * resonance(time, 740, 0.009)
    )


def wood(time: float, noise: float) -> float:
    return (
        0.39 * noise * envelope(time, 0.0008, 0.006)
        + resonance(time, 560, 0.023)
        + 0.38 * resonance(time, 970, 0.014)
        + 0.19 * resonance(time, 1680, 0.010)
    )


def bubble(time: float, noise: float) -> float:
    phase = math.tau * (480 * time + 540 * 0.020 * -math.expm1(-time / 0.020))
    return (
        envelope(time, 0.0026, 0.024) * (math.sin(phase) + 0.15 * math.sin(phase * 2))
        + 0.18 * noise * envelope(time, 0.0012, 0.006)
    )


def metal_tap(time: float, noise: float) -> float:
    return (
        0.25 * noise * envelope(time, 0.0005, 0.006)
        + 0.70 * resonance(time, 1250, 0.022)
        + 0.45 * resonance(time, 2380, 0.037)
        + 0.26 * resonance(time, 3660, 0.025)
        + 0.10 * resonance(time, 5180, 0.012)
    )


def metal_double(time: float, noise: float) -> float:
    return metal_tap(time - 0.002, noise) + 0.74 * metal_tap(time - 0.071, noise)


def metal_spring(time: float, noise: float) -> float:
    phase = math.tau * (780 * time + 85 * 0.026 * -math.expm1(-time / 0.026))
    vibration = 0.8 * math.sin(math.tau * 85 * time) * math.exp(-time / 0.035)
    return (
        envelope(time, 0.0006, 0.026) * math.sin(phase + vibration)
        + 0.33 * resonance(time, 1970, 0.037)
        + 0.22 * resonance(time, 3410, 0.022)
        + 0.18 * noise * envelope(time, 0.0005, 0.006)
    )


def paper_flip(time: float, noise: float) -> float:
    folds = (
        0.90 * envelope(time - 0.002, 0.006, 0.019)
        + 0.65 * envelope(time - 0.036, 0.014, 0.040)
        + 0.55 * envelope(time - 0.090, 0.006, 0.020)
    )
    ripple = 0.58 + 0.42 * math.sin(math.tau * 73 * time) ** 2
    return noise * folds * ripple


def paper_crumple(time: float, noise: float) -> float:
    texture = 0.22 * envelope(time, 0.014, 0.070)
    for onset, strength in [(0.008, 0.8), (0.028, 0.5), (0.052, 0.9),
                            (0.077, 0.6), (0.112, 0.7), (0.143, 0.4)]:
        texture += strength * envelope(time - onset, 0.0012, 0.006)
    return noise * texture


def copy_chime(time: float, _: float) -> float:
    return bell(time, 1280) + 0.31 * bell(time - 0.027, 1760)


def write_sound(name: str, duration: float, peak_level: float, voice: Callable[[float, float], float],
                noise_band: tuple[float, float] | None = None, seed: int = 0) -> None:
    count = round(SAMPLE_RATE * duration)
    noise = band_noise(count, *noise_band, seed) if noise_band else [0.0] * count
    samples = []
    for index, texture in enumerate(noise):
        time = index / SAMPLE_RATE
        fade_out = min(1.0, (duration - time) / 0.012)
        samples.append(voice(time, texture) * max(0.0, fade_out))

    peak = max(abs(value) for value in samples)
    pcm = b"".join(struct.pack("<h", round(value / peak * peak_level * 32767)) for value in samples)
    path = OUTPUT / f"{name}.wav"
    with wave.open(str(path), "wb") as sound:
        sound.setnchannels(1)
        sound.setsampwidth(2)
        sound.setframerate(SAMPLE_RATE)
        sound.writeframes(pcm)
    print(path)


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    write_sound("CopyChime", 0.22, 0.72, copy_chime)
    write_sound("CopyShutter", 0.158, 0.64, shutter, (620, 6100), seed=11)
    write_sound("CopySoftClick", 0.092, 0.54, soft_click, (730, 3150), seed=23)
    write_sound("CopyWood", 0.120, 0.57, wood, (480, 3000), seed=37)
    write_sound("CopyBubble", 0.138, 0.53, bubble, (800, 4800), seed=51)
    write_sound("CopyMetalTap", 0.190, 0.58, metal_tap, (1100, 6600), seed=67)
    write_sound("CopyMetalDouble", 0.235, 0.60, metal_double, (1000, 6300), seed=71)
    write_sound("CopyMetalSpring", 0.210, 0.58, metal_spring, (900, 5700), seed=83)
    write_sound("CopyPaperFlip", 0.225, 0.60, paper_flip, (240, 7800), seed=97)
    write_sound("CopyPaperCrumple", 0.245, 0.59, paper_crumple, (420, 6500), seed=109)
