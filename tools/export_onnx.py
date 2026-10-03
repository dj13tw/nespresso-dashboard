"""Export SegFormer-B2 (ADE20K) to ONNX for the web version, with int8 weights.

Input : "image" float32 [1, 3, 512, 512], RGB in 0..1
Outputs: "wall", "barrier" float32 [1, 1, 128, 128] (same meaning as the Core ML model)

Usage: python export_onnx.py [--out ../web/build/wall-b2.onnx]
"""
import argparse
from pathlib import Path

import torch
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import SegformerForSemanticSegmentation

from convert_model import WallProbability

MODEL_ID = "nvidia/segformer-b2-finetuned-ade-512-512"
SIZE = 512


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="../web/build/wall-b2.onnx")
    args = ap.parse_args()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    fp32 = out.with_suffix(".fp32.onnx")

    segformer = SegformerForSemanticSegmentation.from_pretrained(MODEL_ID, torchscript=True).eval()
    model = WallProbability(segformer).eval()
    torch.onnx.export(model, torch.rand(1, 3, SIZE, SIZE), str(fp32), input_names=["image"],
                      output_names=["wall", "barrier"], opset_version=17, dynamo=False)
    quantize_dynamic(str(fp32), str(out), weight_type=QuantType.QUInt8, op_types_to_quantize=["MatMul", "Conv"])
    fp32.unlink()
    print("saved", out, out.stat().st_size // 1024, "KB")


if __name__ == "__main__":
    main()
