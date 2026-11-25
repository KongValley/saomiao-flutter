import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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

class FileExporter {
  const FileExporter({
    this._saveFile,
    this._share,
  });

  final SaveFileCallback? _saveFile;
  final ShareCallback? _share;

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
}
