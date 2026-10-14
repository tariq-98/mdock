"""Converts torchvision ResNet-50 (ImageNet) to Core ML ML Programs for mdock-ml.

Writes two packages next to this script, under build/:
  resnet50.mlpackage         image input (224x224 RGB) -> classLabel + classLabel_probs
  resnet50_tensor.mlpackage  float32 tensor input [1,3,224,224] (already normalised) -> logits [1,1000]

Run with the venv: accel/ml/.venv/bin/python accel/ml/convert_resnet50.py
"""
import os
import coremltools as ct
import numpy as np
import torch
import torchvision

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build")
os.makedirs(out, exist_ok=True)

weights = torchvision.models.ResNet50_Weights.IMAGENET1K_V2
model = torchvision.models.resnet50(weights=weights).eval()
labels = weights.meta["categories"]
example = torch.rand(1, 3, 224, 224)
traced = torch.jit.trace(model, example)
# The classifier variant ends in a softmax so classLabel_probs are probabilities.
traced_probs = torch.jit.trace(torch.nn.Sequential(model, torch.nn.Softmax(dim=1)).eval(), example)

# ImageNet normalisation folded into the image preprocessing: y = scale * x + bias per channel.
mean, std = [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]
scale = 1 / (255 * np.mean(std))  # Core ML takes one scale; per-channel std differences are small.
bias = [-m / s for m, s in zip(mean, std)]

image_model = ct.convert(
    traced_probs,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=scale, bias=bias, color_layout=ct.colorlayout.RGB)],
    classifier_config=ct.ClassifierConfig(labels),
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS14,
)
image_model.short_description = "ResNet-50 ImageNet classifier (torchvision IMAGENET1K_V2)"
image_model.save(os.path.join(out, "resnet50.mlpackage"))

tensor_model = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=example.shape, dtype=np.float32)],
    outputs=[ct.TensorType(name="logits", dtype=np.float32)],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS14,
)
tensor_model.short_description = "ResNet-50 logits from a normalised NCHW float32 tensor"
tensor_model.save(os.path.join(out, "resnet50_tensor.mlpackage"))
print("wrote", out)
