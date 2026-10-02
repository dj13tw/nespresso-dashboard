"""End-to-end check of the Swift processing code on a real photo, without an iPhone.

Computes the same 160x160 wall probability the Core ML model outputs (via PyTorch), then runs
the Swift package's wallpaint-cli (MaskRefiner + optional MagicWand + Recolorer) and saves
original | matte | result side by side.

Usage: python swift_pipeline_check.py samples/s4.jpg "#6F8F8A" out/s4-swift.jpg [--wand X Y]
Build the CLI first: swift build -c release --package-path ../Packages/WallPainterCore
"""
import argparse
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from transformers import SegformerForSemanticSegmentation

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "Packages/WallPainterCore/.build/release/wallpaint-cli"
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("color")
    ap.add_argument("out")
    ap.add_argument("--wand", nargs=2, type=int)
    args = ap.parse_args()

    img = Image.open(args.image).convert("RGB")
    model = SegformerForSemanticSegmentation.from_pretrained("nvidia/segformer-b5-finetuned-ade-640-640").eval()
    x = (np.asarray(img.resize((640, 640), Image.BILINEAR), dtype=np.float32) / 255 - MEAN) / STD
    with torch.no_grad():
        p = torch.softmax(model(pixel_values=torch.from_numpy(x).permute(2, 0, 1)[None]).logits, 1)[0]
    prob = p[0].numpy().astype(np.float32)
    barrier = (p[3] + p[5]).numpy().astype(np.float32)  # floor + ceiling, as in convert_model.py

    w, h = img.size
    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        np.asarray(img.convert("RGBA"), dtype=np.uint8).tofile(t / "in.rgba")
        prob.tofile(t / "prob.f32")
        barrier.tofile(t / "barrier.f32")
        cmd = [str(CLI), str(t / "in.rgba"), str(w), str(h), str(t / "prob.f32"), str(prob.shape[1]),
               str(prob.shape[0]), args.color, str(t / "out.rgba"), str(t / "mask.u8")]
        if args.wand:
            cmd += [str(v) for v in args.wand] + [str(t / "barrier.f32")]
        print(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip())
        out = Image.fromarray(np.fromfile(t / "out.rgba", dtype=np.uint8).reshape(h, w, 4)[..., :3])
        mask = Image.fromarray(np.fromfile(t / "mask.u8", dtype=np.uint8).reshape(h, w)).convert("RGB")

    cw = 640
    ch = round(h * cw / w)
    sheet = Image.new("RGB", (cw * 3, ch))
    for i, im in enumerate([img, mask, out]):
        sheet.paste(im.resize((cw, ch)), (i * cw, 0))
    sheet.save(args.out, quality=88)


if __name__ == "__main__":
    main()
