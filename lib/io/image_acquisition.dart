import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

class PickedImageInput {
  const PickedImageInput({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;
}

class ImageAcquisition {
  ImageAcquisition({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  bool get supportsCamera => _picker.supportsImageSource(ImageSource.camera);

  Future<List<PickedImageInput>> pickFromGallery({int limit = 20}) async {
    try {
      final files = await _picker.pickMultiImage(
        limit: limit,
        requestFullMetadata: false,
      );
      if (files.isEmpty) return const <PickedImageInput>[];
      final out = <PickedImageInput>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        out.add(
          PickedImageInput(
            name: file.name.isNotEmpty ? file.name : '扫描页_${out.length + 1}.jpg',
            bytes: bytes,
          ),
        );
      }
      return out;
    } on PlatformException catch (err) {
      if (err.code.toLowerCase().contains('access') ||
          err.code.toLowerCase().contains('denied') ||
          err.code.toLowerCase().contains('permission')) {
        throw StateError('没有相册权限：请在系统设置里允许访问照片');
      }
      throw StateError('打开相册失败，请重试');
    } catch (_) {
      throw StateError('打开相册失败，请重试');
    }
  }

  Future<PickedImageInput?> takePhoto() async {
    if (!supportsCamera) {
      throw StateError('当前平台不支持直接调用相机，请使用「选择图片」导入');
    }
    try {
      final file = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        requestFullMetadata: false,
      );
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('照片读取失败，请重试');
      }
      return PickedImageInput(
        name: file.name.isNotEmpty ? file.name : '拍照文档.jpg',
        bytes: bytes,
      );
    } on PlatformException catch (err) {
      if (err.code.toLowerCase().contains('camera_access') ||
          err.code.toLowerCase().contains('denied') ||
          err.code.toLowerCase().contains('permission')) {
        throw StateError('没有相机权限：请在系统设置里允许使用相机');
      }
      throw StateError('打开相机失败，请重试');
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('打开相机失败，请重试');
    }
  }
}
