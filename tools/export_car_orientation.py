"""Converts the CFV car-orientation model to CoreML: GapCheck/Pipeline/CarOrientation.mlpackage.

Model and weights: "Car Full View Dataset: Fine-Grained Predictions of Car Orientation from Images" (Catruna et al.,
Electronics 12(24) 4947, 2023), https://github.com/fort-cyber/car-orientation, Apache-2.0. The class below rebuilds
their `ConvNextSmallMultiModel` (models/multitask_models.py) so the checkpoint loads strictly.

Input as in training: the whole crop resized to 224x224, RGB, values 0-1 (`transforms.ToTensor()`, no mean/std).
Output: probabilities for 8 orientation classes (datasets/angle_dataset.py), 0 = front facing the camera.

Run from the repo root, with the weights downloaded to tools/ (gitignored):
    curl -L -o tools/convnext-multi-weak.pth \
        https://huggingface.co/fort-cyber/Car-orientation-image/resolve/main/convnext-multi-weak.pth
    .venv/bin/python tools/export_car_orientation.py
"""
import os

import coremltools as ct
import numpy as np
import timm
import torch
import torch.nn as nn
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from PIL import Image

WEIGHTS = "tools/convnext-multi-weak.pth"
OUTPUT = "GapCheck/Pipeline/CarOrientation.mlpackage"
SAMPLE = ".venv/lib/python3.12/site-packages/ultralytics/assets/bus.jpg"
LABELS = ["front", "front-left", "left", "back-left", "back", "back-right", "right", "front-right"]


class ConvNextSmallMultiModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = timm.create_model("convnext_small", pretrained=False)
        self.backbone.head.fc = nn.Linear(in_features=768, out_features=1024, bias=True)
        self.class_prediction = nn.Linear(1024, 8)
        self.angle_prediction = nn.Linear(1024 + 8, 1)
        self.sigmoid = nn.Sigmoid()

    def forward(self, x):
        x = self.backbone(x)
        class_pred = self.class_prediction(x)
        angle_pred = self.sigmoid(self.angle_prediction(torch.cat((x, class_pred), dim=1)))
        return class_pred, angle_pred


class ClassProbabilities(nn.Module):
    """Only the class head, as probabilities: the app needs front vs back, not the angle."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        return torch.softmax(self.model(x)[0], dim=1)


def main():
    model = ConvNextSmallMultiModel()
    # weights_only: the checkpoint is a pickle; this refuses anything but tensors.
    model.load_state_dict(torch.load(WEIGHTS, map_location="cpu", weights_only=True), strict=True)
    wrapped = ClassProbabilities(model).eval()
    traced = torch.jit.trace(wrapped, torch.rand(1, 3, 224, 224))

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        classifier_config=ct.ClassifierConfig(LABELS),
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel = linear_quantize_weights(
        mlmodel, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric")))
    mlmodel.short_description = "CFV ConvNeXt-small car orientation (Apache-2.0), 8-bit weights. Input: car crop."
    mlmodel.save(OUTPUT)

    # Parity: the same 224x224 picture through PyTorch (fp32) and the saved CoreML model (8-bit weights).
    image = Image.open(SAMPLE).convert("RGB").resize((224, 224), Image.BILINEAR)
    x = torch.from_numpy(np.asarray(image, dtype=np.float32) / 255).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        torch_probs = wrapped(x)[0].numpy()
    saved = ct.models.MLModel(OUTPUT)
    probs_name = saved.get_spec().description.predictedProbabilitiesName
    coreml_probs_by_label = saved.predict({"image": image})[probs_name]
    coreml_probs = np.array([coreml_probs_by_label[label] for label in LABELS])
    top_torch, top_coreml = LABELS[int(torch_probs.argmax())], LABELS[int(coreml_probs.argmax())]
    difference = float(np.abs(torch_probs - coreml_probs).max())
    print(f"torch top {top_torch} {torch_probs.max():.3f}, coreml top {top_coreml} {coreml_probs.max():.3f}, "
          f"largest difference {difference:.4f}")
    assert top_torch == top_coreml and difference <= 0.05, "CoreML output differs from PyTorch"
    size_mb = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(OUTPUT) for f in fs) / 1e6
    print(f"parity ok; {OUTPUT} {size_mb:.1f} MB")


if __name__ == "__main__":
    main()
