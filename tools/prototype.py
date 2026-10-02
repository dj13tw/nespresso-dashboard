"""Reference implementation of the on-device pipeline, used to tune parameters.

Mirrors WallSegmenter + MaskRefiner + Recolorer in the iOS app:
  1. SegFormer (ADE20K) -> wall probability
  2. Upsample to working resolution, refine with a guided filter on luminance
  3. Recolor: new = target * (pixel luminance / mean wall luminance), in linear RGB

Usage: python prototype.py samples/s2.jpg "#7A9E9F" out.jpg [--model nvidia/segformer-b5-finetuned-ade-640-640]
"""
import argparse
import os

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
from transformers import SegformerForSemanticSegmentation

WALL = 0  # ADE20K class index for "wall"
# Tuning knobs: guided filter radius = longer side / RADIUS_DIV; model input size.
RADIUS_DIV = float(os.environ.get("RADIUS_DIV", "80"))
INPUT = int(os.environ.get("INPUT", "640"))
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def wall_probability(model, img):
    x = np.asarray(img.resize((INPUT, INPUT), Image.BILINEAR), dtype=np.float32) / 255
    x = (x - MEAN) / STD
    x = torch.from_numpy(x).permute(2, 0, 1)[None]
    with torch.no_grad():
        logits = model(pixel_values=x).logits
        logits = F.interpolate(logits, size=(INPUT, INPUT), mode="bilinear", align_corners=False)
        return torch.softmax(logits, 1)[0, WALL].numpy()


def box(a, r):
    """Mean filter of radius r via integral image (same as the Swift version)."""
    h, w = a.shape
    s = np.pad(a, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    ys = np.arange(h)
    xs = np.arange(w)
    y0 = np.clip(ys - r, 0, h)
    y1 = np.clip(ys + r + 1, 0, h)
    x0 = np.clip(xs - r, 0, w)
    x1 = np.clip(xs + r + 1, 0, w)
    total = s[y1][:, x1] - s[y0][:, x1] - s[y1][:, x0] + s[y0][:, x0]
    area = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return total / area


def guided_filter(guide, p, r, eps):
    mi = box(guide, r)
    mp = box(p, r)
    cov = box(guide * p, r) - mi * mp
    var = box(guide * guide, r) - mi * mi
    a = cov / (var + eps)
    b = mp - a * mi
    return box(a, r) * guide + box(b, r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("color")
    ap.add_argument("out")
    ap.add_argument("--model", default="nvidia/segformer-b5-finetuned-ade-640-640")
    ap.add_argument("--mask-out")
    args = ap.parse_args()

    img = Image.open(args.image).convert("RGB")
    model = SegformerForSemanticSegmentation.from_pretrained(args.model).eval()
    prob = wall_probability(model, img)

    w, h = img.size
    rgb = np.asarray(img, dtype=np.float32) / 255
    lin = srgb_to_linear(rgb)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)

    prob = np.asarray(Image.fromarray(prob).resize((w, h), Image.BILINEAR))
    guide = rgb.mean(2)  # gamma-encoded gray, closer to perceived edges
    r = max(2, round(max(w, h) / RADIUS_DIV))
    mask = np.clip(guided_filter(guide, prob, r, 1e-3), 0, 1)
    # Sharpen the soft probability into a matte, keeping a thin feathered edge.
    mask = np.clip((mask - 0.35) / 0.3, 0, 1)
    mask = mask * mask * (3 - 2 * mask)

    hexs = args.color.lstrip("#")
    target = srgb_to_linear(np.array([int(hexs[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32) / 255)

    wall_lum = (lum * mask).sum() / max(mask.sum(), 1)
    shading = lum / max(wall_lum, 1e-4)
    painted = target[None, None, :] * shading[..., None]
    out = lin * (1 - mask[..., None]) + painted * mask[..., None]
    Image.fromarray((linear_to_srgb(out) * 255 + 0.5).astype(np.uint8)).save(args.out, quality=90)
    if args.mask_out:
        Image.fromarray((mask * 255).astype(np.uint8)).save(args.mask_out)
    print(f"wall coverage {mask.mean():.1%}, mean wall luminance {wall_lum:.3f}")


if __name__ == "__main__":
    main()
