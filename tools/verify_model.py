"""Runs the converted Core ML model on sample photos (macOS only: needs the Core ML runtime).

Checks that the model loads, produces both outputs at 160x160, and finds the walls in
samples whose wall coverage is known from the PyTorch reference.
"""
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
# Sample -> expected fraction of 160x160 cells with wall probability > 0.5 (PyTorch reference).
EXPECTED = {"s2.jpg": (0.35, 0.50), "s4.jpg": (0.22, 0.36)}


def main():
    model = ct.models.MLModel(str(HERE.parent / "Models/WallSegmenter.mlpackage"))
    ok = True
    for name, (lo, hi) in EXPECTED.items():
        image = Image.open(HERE / "samples" / name).convert("RGB").resize((640, 640), Image.BILINEAR)
        out = model.predict({"image": image})
        wall, barrier = np.asarray(out["wall"]), np.asarray(out["barrier"])
        assert wall.shape == (1, 1, 160, 160), wall.shape
        assert barrier.shape == (1, 1, 160, 160), barrier.shape
        coverage = float((wall > 0.5).mean())
        floor_ceiling = float((barrier > 0.5).mean())
        good = lo <= coverage <= hi
        ok &= good
        print(f"{name}: wall {coverage:.1%} (expected {lo:.0%}-{hi:.0%}), floor/ceiling {floor_ceiling:.1%}",
              "OK" if good else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
