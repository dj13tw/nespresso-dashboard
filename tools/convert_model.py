"""Convert SegFormer-B5 (ADE20K) into a Core ML model that outputs wall probability.

Input : "image"  RGB 640x640 (Vision scales the photo to fit)
Outputs: "wall"    Float32 [1, 1, 160, 160], probability that each cell is a wall
         "barrier" Float32 [1, 1, 160, 160], probability of floor or ceiling, which the
                   magic wand must not spread into

Weights are linearly quantized to 8 bits, which keeps the model under GitHub's
100 MB file limit with no visible change in the mask.

Usage: python convert_model.py [--out ../Models/WallSegmenter.mlpackage]
"""
import argparse

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from transformers import SegformerForSemanticSegmentation

MODEL_ID = "nvidia/segformer-b5-finetuned-ade-640-640"
SIZE = 640
WALL, FLOOR, CEILING = 0, 3, 5  # ADE20K class indices


class WallProbability(torch.nn.Module):
    def __init__(self, segformer):
        super().__init__()
        self.segformer = segformer
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, image):
        x = (image - self.mean) / self.std
        logits = self.segformer(pixel_values=x)[0]
        p = torch.softmax(logits, dim=1)
        return p[:, WALL:WALL + 1], p[:, FLOOR:FLOOR + 1] + p[:, CEILING:CEILING + 1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="../Models/WallSegmenter.mlpackage")
    ap.add_argument("--no-quantize", action="store_true")
    args = ap.parse_args()

    segformer = SegformerForSemanticSegmentation.from_pretrained(MODEL_ID, torchscript=True).eval()
    model = WallProbability(segformer).eval()
    example = torch.rand(1, 3, SIZE, SIZE)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="wall", dtype=np.float32), ct.TensorType(name="barrier", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    if not args.no_quantize:
        config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric"))
        mlmodel = cto.linear_quantize_weights(mlmodel, config=config)

    mlmodel.short_description = "Wall and floor/ceiling probability maps (ADE20K) from SegFormer-B5"
    mlmodel.author = "NVIDIA SegFormer, converted for WallPainter"
    mlmodel.license = "NVIDIA Source Code License for SegFormer (non-commercial)"
    mlmodel.save(args.out)
    print("saved", args.out)


if __name__ == "__main__":
    main()
