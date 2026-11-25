# 扫描件工坊 · Flutter 跨平台版

把文档照片在**设备本地**处理为平整、干净的扫描件，并导出多页 PDF。全程不联网、不上传、无需服务器，支持 **Android / iOS / Windows 桌面**。

本工程基于原 Expo 版（`F:\workspace\saomiao-expo`）使用 Flutter 技术栈重新打造：
- **核心算法与零依赖 PDF 生成器 100% 保持一致**（透视矫正、背景除法去阴影、Sauvola 二值化、自动四角检测、`/DCTDecode` 多页 PDF）。
- **Material 3 自适应界面**：移动端采用底部导航 + `ModalBottomSheet`，桌面/宽屏采用双栏工作区，并支持双指/双击缩放、拖放排序与四角拖动放大镜。
- **Dart `compute` / `Isolate` 后台渲染**：原生端图像解码、滤波增强与 PDF 打包在后台 Isolate 执行，UI 全程不卡顿。

---

## 目录结构

```text
lib/
├── main.dart                         # 应用入口与 Material 3 主题、zh-CN 本地化
├── engine/                           # 纯 Dart 算法引擎与零依赖 PDF 生成（无 Flutter 依赖）
│   ├── options.dart                  # ScanOptions 默认值与容错规范化
│   ├── filters.dart                  # BT.601 灰度、背景照度场去阴影、白平衡、LUT、锐化、Sauvola 二值化
│   ├── geometry.dart                 # 8x8 单应性矩阵、双线性透视矫正、倾角检测与 deskew
│   ├── resize.dart                   # 面积平均降采样、双线性放大、90° 旋转
│   ├── detect.dart                   # Otsu + 最大连通域 + 凸包 + PCA 直线拟合四角检测
│   ├── pipeline.dart                 # renderPage / detectCorners 主管线
│   └── pdf.dart                      # 自写 PDF 1.4 生成器（JPEG /DCTDecode + UTF-16BE 中文标题）
├── io/                               # 跨平台像素编解码、持久化、选图与导出
│   ├── pixel_io.dart                 # package:image 解码/EXIF 摆正/编码 + Flutter 编解码兜底（HEIC 等）
│   ├── app_storage*.dart             # 持久化存储（pages.json + orig/ + 渲染缓存）
│   ├── image_acquisition.dart        # 拍照 / 多选图片（桌面端无相机时自动适配）
│   └── file_export.dart              # share_plus 系统分享 + file_picker 保存到本地文件
├── jobs/
│   ├── render_jobs.dart              # compute() 后台渲染、SHA-256 指纹缓存（LRU 保留 30 项）
│   └── demo_generator.dart           # 内置示例文档生成器（便于无相机环境快速体验）
├── state/
│   ├── page_models.dart              # PageItem、PagesState 状态机、预设与参数元信息
│   └── scanner_controller.dart       # ChangeNotifier 控制器、200ms debounce 渲染与防抖持久化
└── ui/
    ├── theme.dart                    # Material 3 ColorScheme（#2563EB 主题色）与组件主题
    ├── screens/editor_screen.dart    # 自适应主界面（空状态 / 编辑态 / 宽屏双栏 / 窄屏底部抽屉）
    └── widgets/                      # TopBar / PageStrip / StyleSheet / ParamsSheet / ExportSheet / CornersOverlay / ProcessingBanner
```

---

## 常用开发与验证命令

```powershell
# 运行全部单元测试与 Widget 测试
flutter test

# 静态分析
flutter analyze

# 构建 Android APK（Release）
flutter build apk --release

# 构建 Windows 桌面端（Release）
flutter build windows --release
```

---

## 与原 Expo 版的主要改进

1. **后台线程渲染**：利用 Dart `compute()` 在独立 Isolate 执行重计算，消除单线程卡顿。
2. **原生全平台适配**：同一套代码库支持 Android、iOS 与 Windows 桌面端。
3. **Material 3 自适应交互**：
   - 宽屏（`>= 840dp`）自动切换为「左侧画布 + 右侧参数检验栏」双栏工作区；
   - 缩略图支持真正的长按拖放排序（`ReorderableListView`）；
   - 四角校正拖动角点时在屏幕对侧显示局部**像素放大镜**与三分网格辅助线；
   - 参数面板补齐了引擎支持的**自动纠偏（deskew）**与**反相显示（invert）**开关。
