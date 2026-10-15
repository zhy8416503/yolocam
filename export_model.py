#!/usr/bin/env python3
"""YOLOv8n -> Core ML (.mlmodel) for the YOLOCam iOS app.

Pipeline: yolov8n.pt -> ONNX (ultralytics) -> Core ML neuralnetwork format
(coremltools, FP16). The .mlmodel is a single file that Xcode compiles into
the app bundle; the app loads it via MLModel + Vision.

Fallback: if the neuralnetwork conversion fails (e.g. an unsupported op),
falls back to ultralytics' own Core ML export (.mlpackage, mlprogram format).
In that case rename the pbxproj reference from yolov8n.mlmodel to the
.mlpackage accordingly.
"""
import os
import sys

OUT_MLMODEL = "yolov8n.mlmodel"

print("== step 1: download yolov8n.pt and export ONNX ==")
from ultralytics import YOLO

model = YOLO("yolov8n.pt")  # auto-downloads official weights on first run
onnx_path = model.export(format="onnx", imgsz=640, simplify=True)
print("ONNX:", onnx_path)
if isinstance(onnx_path, (list, tuple)):
    onnx_path = onnx_path[0]

print("== step 2: ONNX -> Core ML (neuralnetwork, FP16) ==")
try:
    import coremltools as ct

    mlmodel = ct.convert(
        onnx_path,
        inputs=[ct.ImageType(name="images", shape=(1, 3, 640, 640),
                             scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        convert_to="neuralnetwork",
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.save(OUT_MLMODEL)
    print("saved:", OUT_MLMODEL, os.path.getsize(OUT_MLMODEL), "bytes")

    # inspect + sanity check the converted model
    spec = mlmodel.get_spec()
    for i in spec.description.input:
        print("input:", i.name, i.type.WhichOneof("Type"),
              getattr(i.type.imageType, "width", ""), getattr(i.type.imageType, "height", ""))
    for o in spec.description.output:
        print("output:", o.name, o.type.WhichOneof("Type"),
              list(o.type.multiArrayType.shape))
    print("RESULT=mlmodel")
except Exception as e:  # noqa: BLE001
    print("neuralnetwork conversion failed:", e)
    print("== fallback: ultralytics native Core ML export (.mlpackage) ==")
    pkg = model.export(format="coreml", half=True, imgsz=640, nms=False)
    print("PACKAGE:", pkg)
    print("RESULT=mlpackage")
