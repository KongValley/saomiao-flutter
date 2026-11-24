import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'app_storage.dart';

enum ExportDestination {
  share,
  save,
}

class FileExporter {
  const FileExporter();

  Future<String> deliver({
    required AppStorage storage,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required ExportDestination destination,
  }) async {
    if (destination == ExportDestination.save) {
      final savedUri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        dialogTitle: '保存扫描件',
      );
      if (kIsWeb) {
        return savedUri != null ? '已保存：$fileName' : '已开始下载：$fileName';
      }
      if (savedUri == null) {
        return '';
      }
      return '已保存到：$fileName';
    }

    // 分享：原生平台写入临时文件再分享；Web 直接使用内存字节
    final tempPath = await storage.writeExportTempFile(bytes, fileName);
    final xfile = tempPath != null
        ? XFile(tempPath, mimeType: mimeType, name: fileName)
        : XFile.fromData(bytes, mimeType: mimeType, name: fileName);
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[xfile],
        subject: fileName,
      ),
    );
    return kIsWeb ? '已导出：$fileName' : '已打开系统分享';
  }
}
