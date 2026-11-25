import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

const int kMaxImportFileBytes = 60 * 1024 * 1024; // 60MB

class PickedImageInput {
  const PickedImageInput({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;
}

class PickedImageEntry {
  const PickedImageEntry({
    required this.name,
    required this._readLength,
    required this._readBytes,
  });

  factory PickedImageEntry.fromInput(PickedImageInput input) {
    return PickedImageEntry(
      name: input.name,
      readLength: () async => input.bytes.length,
      readBytes: () async => input.bytes,
    );
  }

  final String name;
  final Future<int> Function() _readLength;
  final Future<Uint8List> Function() _readBytes;

  Future<int> length() => _readLength();
  Future<Uint8List> readAsBytes() => _readBytes();
}

class ImageAcquisition {
  ImageAcquisition({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  bool get supportsCamera => _picker.supportsImageSource(ImageSource.camera);

  PickedImageEntry _entryFromXFile(XFile file, String fallbackName) {
    return PickedImageEntry(
      name: file.name.isNotEmpty ? file.name : fallbackName,
      readLength: file.length,
      readBytes: file.readAsBytes,
    );
  }

  Future<List<PickedImageEntry>> pickFromGalleryEntries({int limit = 20}) async {
    try {
      final files = await _picker.pickMultiImage(
        limit: limit,
        requestFullMetadata: false,
      );
      if (files.isEmpty) return const <PickedImageEntry>[];
      return <PickedImageEntry>[
        for (var i = 0; i < files.length; i++)
          _entryFromXFile(files[i], '扫描页_${i + 1}.jpg'),
      ];
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

  Future<List<PickedImageInput>> pickFromGallery({int limit = 20}) async {
    final entries = await pickFromGalleryEntries(limit: limit);
    if (entries.isEmpty) return const <PickedImageInput>[];
    final out = <PickedImageInput>[];
    for (final entry in entries) {
      final len = await entry.length();
      if (len <= 0 || len > kMaxImportFileBytes) continue;
      final bytes = await entry.readAsBytes();
      if (bytes.isEmpty || bytes.length > kMaxImportFileBytes) continue;
      out.add(PickedImageInput(name: entry.name, bytes: bytes));
    }
    return out;
  }

  Future<PickedImageEntry?> takePhotoEntry() async {
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
      return _entryFromXFile(file, '拍照文档.jpg');
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

  Future<PickedImageInput?> takePhoto() async {
    final entry = await takePhotoEntry();
    if (entry == null) return null;
    final len = await entry.length();
    if (len > kMaxImportFileBytes) {
      throw StateError('「${entry.name}」超过 60MB，请压缩后再试');
    }
    final bytes = await entry.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('照片读取失败，请重试');
    }
    return PickedImageInput(name: entry.name, bytes: bytes);
  }

  Future<List<PickedImageEntry>> retrieveLostEntries() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const <PickedImageEntry>[];
    }
    try {
      final response = await _picker.retrieveLostData();
      if (response.isEmpty) return const <PickedImageEntry>[];
      if (response.exception != null) {
        final code = response.exception!.code.toLowerCase();
        if (code.contains('access') ||
            code.contains('denied') ||
            code.contains('permission')) {
          throw StateError('没有相机或相册权限：请在系统设置里允许访问');
        }
        throw StateError('恢复上次选图失败，请重试');
      }
      final files = response.files ??
          (response.file != null ? <XFile>[response.file!] : const <XFile>[]);
      return <PickedImageEntry>[
        for (var i = 0; i < files.length; i++)
          _entryFromXFile(files[i], '恢复文档_${i + 1}.jpg'),
      ];
    } on MissingPluginException {
      return const <PickedImageEntry>[];
    } on UnimplementedError {
      return const <PickedImageEntry>[];
    } on StateError {
      rethrow;
    } catch (_) {
      return const <PickedImageEntry>[];
    }
  }
}
