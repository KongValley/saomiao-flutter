import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'app_storage.dart';

enum ExportDestination {
  share,
  save,
}

typedef SaveFileCallback = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
  required String dialogTitle,
});

typedef ShareCallback = Future<ShareResult> Function(ShareParams params);
typedef PickDirectoryCallback = Future<String?> Function({required String dialogTitle});

class FileExporter {
  const FileExporter({
    this._saveFile,
    this._share,
    this._pickDirectory,
  });

  final SaveFileCallback? _saveFile;
  final ShareCallback? _share;
  final PickDirectoryCallback? _pickDirectory;

  Future<String> deliver({
    required AppStorage storage,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required ExportDestination destination,
  }) async {
    if (destination == ExportDestination.save) {
      final savedUri = _saveFile != null
          ? await _saveFile(
              fileName: fileName,
              bytes: bytes,
              mimeType: mimeType,
              dialogTitle: '保存扫描件',
            )
          : await FilePicker.saveFile(
              fileName: fileName,
              bytes: bytes,
              mimeType: mimeType,
              dialogTitle: '保存扫描件',
            );
      if (savedUri == null) {
        return '';
      }
      return '已保存到：$fileName';
    }

    // 写入临时文件供系统分享；若未生成临时路径则回退为内存字节
    final tempPath = await storage.writeExportTempFile(bytes, fileName);
    final xfile = tempPath != null
        ? XFile(tempPath, mimeType: mimeType, name: fileName)
        : XFile.fromData(bytes, mimeType: mimeType, name: fileName);
    final params = ShareParams(
      files: <XFile>[xfile],
      subject: fileName,
    );
    final result = _share != null
        ? await _share(params)
        : await SharePlus.instance.share(params);

    if (result.status == ShareResultStatus.dismissed) {
      return '';
    }
    return result.status == ShareResultStatus.success ? '已分享：$fileName' : '已打开系统分享';
  }

  Future<String> deliverBatchToDirectory({
    required List<({String fileName, Uint8List bytes})> files,
  }) async {
    if (files.isEmpty) return '';
    String? dirPath;
    if (_pickDirectory != null) {
      dirPath = await _pickDirectory(dialogTitle: '选择保存图片文件夹');
    } else {
      final uri = await FilePicker.pickDirectory(dialogTitle: '选择保存图片文件夹');
      if (uri == null) return '';
      if (uri.isScheme('file')) {
        dirPath = uri.toFilePath();
      } else {
        // Android SAF content:// 目录不支持直接 File 路径写入，引导改用 ZIP 导出
        throw StateError('当前系统目录授权暂不支持批量裸写，请使用「保存全部页图片（ZIP）」');
      }
    }
    if (dirPath == null || dirPath.trim().isEmpty) return '';
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    for (final entry in files) {
      final safeName = p.basename(entry.fileName);
      final target = File(p.join(dir.path, safeName));
      await target.writeAsBytes(entry.bytes, flush: true);
    }
    return '已导出 ${files.length} 个文件到文件夹';
  }
}
