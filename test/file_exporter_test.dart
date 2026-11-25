import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/io/app_storage.dart';
import 'package:saomiao_flutter/io/file_export.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  test('FileExporter.deliver 区分取消分享与成功/不可用状态', () async {
    final storage = MemoryAppStorage();
    final bytes = Uint8List.fromList([1, 2, 3]);

    const dismissedExporter = FileExporter(
      share: _dismissedShare,
    );
    final cancelledMsg = await dismissedExporter.deliver(
      storage: storage,
      bytes: bytes,
      fileName: 'doc.pdf',
      mimeType: 'application/pdf',
      destination: ExportDestination.share,
    );
    expect(cancelledMsg, '');

    const okExporter = FileExporter(
      share: _successShare,
    );
    final okMsg = await okExporter.deliver(
      storage: storage,
      bytes: bytes,
      fileName: 'doc.pdf',
      mimeType: 'application/pdf',
      destination: ExportDestination.share,
    );
    expect(okMsg.isNotEmpty, isTrue);

    const saveCancelled = FileExporter(
      saveFile: _nullSave,
    );
    final saveCancelledMsg = await saveCancelled.deliver(
      storage: storage,
      bytes: bytes,
      fileName: 'doc.pdf',
      mimeType: 'application/pdf',
      destination: ExportDestination.save,
    );
    expect(saveCancelledMsg, '');
  });
}

Future<ShareResult> _dismissedShare(ShareParams _) async =>
    const ShareResult('', ShareResultStatus.dismissed);

Future<ShareResult> _successShare(ShareParams _) async =>
    const ShareResult('com.example.app', ShareResultStatus.success);

Future<String?> _nullSave({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
  required String dialogTitle,
}) async =>
    null;
