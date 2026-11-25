import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../io/image_acquisition.dart';
import '../theme.dart';

class BurstCameraScreen extends StatefulWidget {
  const BurstCameraScreen({super.key});

  @override
  State<BurstCameraScreen> createState() => _BurstCameraScreenState();
}

class _BurstCameraScreenState extends State<BurstCameraScreen> with WidgetsBindingObserver {
  CameraController? _camController;
  List<CameraDescription> _cameras = const <CameraDescription>[];
  int _cameraIdx = 0;
  FlashMode _flash = FlashMode.auto;
  bool _initializing = true;
  bool _capturing = false;
  String? _error;

  final List<({String name, Uint8List bytes})> _shots =
      <({String name, Uint8List bytes})>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _camController;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      cam.dispose();
      _camController = null;
    } else if (state == AppLifecycleState.resumed) {
      _setupController(_cameraIdx);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camController?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _initializing = false;
            _error = '未检测到可用摄像头';
          });
        }
        return;
      }
      final backIdx = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      _cameraIdx = backIdx >= 0 ? backIdx : 0;
      await _setupController(_cameraIdx);
    } catch (err) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = '相机初始化失败，请检查相机权限或改用系统相机';
        });
      }
    }
  }

  Future<void> _setupController(int index) async {
    await _camController?.dispose();
    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _camController = controller;
    try {
      await controller.initialize();
      await controller.setFlashMode(_flash);
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = '没有相机权限或相机被占用';
        });
      }
    }
  }

  Future<void> _toggleFlash() async {
    final cam = _camController;
    if (cam == null || !cam.value.isInitialized) return;
    final next = switch (_flash) {
      FlashMode.auto => FlashMode.torch,
      FlashMode.torch => FlashMode.off,
      _ => FlashMode.auto,
    };
    try {
      await cam.setFlashMode(next);
      if (mounted) setState(() => _flash = next);
    } catch (_) {}
  }

  Future<void> _capture() async {
    final cam = _camController;
    if (cam == null || !cam.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final file = await cam.takePicture();
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty && mounted) {
        setState(() {
          _shots.add((name: '连拍_${_shots.length + 1}.jpg', bytes: bytes));
        });
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('拍照失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  IconData _flashIcon() {
    switch (_flash) {
      case FlashMode.torch:
        return Icons.flashlight_on_rounded;
      case FlashMode.off:
        return Icons.flash_off_rounded;
      default:
        return Icons.flash_auto_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final cam = _camController;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_initializing)
            const Center(child: CircularProgressIndicator(color: Colors.white))
          else if (_error != null || cam == null || !cam.value.isInitialized)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.no_photography_outlined, size: 42, color: Colors.white70),
                    const SizedBox(height: 12),
                    Text(
                      _error ?? '相机暂不可用',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(const <PickedImageInput>[]),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ),
            )
          else
            Center(
              child: AspectRatio(
                aspectRatio: 1 / cam.value.aspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(cam),
                    IgnorePointer(
                      child: CustomPaint(painter: _CameraGridPainter()),
                    ),
                  ],
                ),
              ),
            ),

          // 顶部控制栏
          Positioned(
            top: topPad + 10,
            left: 14,
            right: 14,
            child: Row(
              children: [
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '连续连拍 · 已拍 ${_shots.length} 张',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                  onPressed: _toggleFlash,
                  icon: Icon(_flashIcon(), color: Colors.white),
                ),
              ],
            ),
          ),

          // 底部连拍队列与快门
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPad + 18),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xE6000000), Color(0x88000000), Colors.transparent],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_shots.isNotEmpty)
                    SizedBox(
                      height: 68,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _shots.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, idx) {
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  _shots[idx].bytes,
                                  width: 50,
                                  height: 68,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Positioned(
                                top: -4,
                                right: -4,
                                child: GestureDetector(
                                  onTap: () => setState(() => _shots.removeAt(idx)),
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: const BoxDecoration(
                                      color: AppColors.danger,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close, size: 12, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox(width: 96),
                      GestureDetector(
                        onTap: _error != null || _initializing ? null : _capture,
                        child: Container(
                          width: 74,
                          height: 74,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                            color: _capturing
                                ? Colors.white54
                                : Colors.white.withValues(alpha: 0.22),
                          ),
                          child: Center(
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 96,
                        child: _shots.isNotEmpty
                            ? FilledButton(
                                onPressed: () {
                                  final list = _shots
                                      .map((s) => PickedImageInput(name: s.name, bytes: s.bytes))
                                      .toList(growable: false);
                                  Navigator.of(context).pop(list);
                                },
                                child: Text('导入(${_shots.length})'),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

class _CameraGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (final t in const [1 / 3, 2 / 3]) {
      canvas.drawLine(
        Offset(size.width * t, 0),
        Offset(size.width * t, size.height),
        p,
      );
      canvas.drawLine(
        Offset(0, size.height * t),
        Offset(size.width, size.height * t),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
