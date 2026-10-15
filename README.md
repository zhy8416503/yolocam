# YOLOCam

iPhone 上的 YOLOv8 实时物体检测 App：打开即用后置摄像头，Core ML 在手机上离线推理，80 类 COCO 物体实时框选。

- 模型：YOLOv8n（Ultralytics 官方权重），官方导出为 Core ML（FP16，6.2MB），打包在 App 内
- 推理：Vision + Core ML，ANE/GPU/CPU 自动调度
- 完全离线：无网络请求

## 构建

GitHub Actions（macos-14）自动构建未签名 IPA：Actions 页面手动点 "Run workflow"，
构建时会自动解压 `yolov8n.mlpackage.zip`（模型以 zip 形式存仓库，省得传散文件）。
产物 `YOLOCam-unsigned.ipa` 在 Artifacts 和 Release 里下载，需自行签名/侧载安装。

## 模型转换（已做过，记录在此）

```bash
python3 export_model.py
# yolov8n.pt -> yolov8n.onnx -> yolov8n.mlmodel (neuralnetwork, FP16)
```

## 使用说明

- 仅支持竖屏
- 首次打开按提示允许相机权限
- 左上角显示推理 fps 和当前目标数
