import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:saomiao_flutter/engine/detect.dart';
import 'package:saomiao_flutter/engine/filters.dart';
import 'package:saomiao_flutter/engine/geometry.dart';
import 'package:saomiao_flutter/engine/options.dart';
import 'package:saomiao_flutter/engine/pdf.dart';
import 'package:saomiao_flutter/engine/pipeline.dart';
import 'package:saomiao_flutter/io/app_storage.dart';
import 'package:saomiao_flutter/io/app_storage_io.dart';
import 'package:saomiao_flutter/io/file_export.dart';
import 'package:saomiao_flutter/io/image_acquisition.dart';
import 'package:saomiao_flutter/io/ocr_service.dart';
import 'package:saomiao_flutter/jobs/render_jobs.dart';
import 'package:saomiao_flutter/main.dart';
import 'package:saomiao_flutter/state/page_models.dart';
import 'package:saomiao_flutter/state/scanner_controller.dart';
import 'package:share_plus/share_plus.dart';

Uint8List _makeStampDocJpeg({int width = 200, int height = 240}) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // 白纸底 + 黑色正文横条 + 红色印章方块 + 蓝色手写签批方块
      if (y >= 40 && y < 56 && x >= 24 && x < 160) {
        im.setPixelRgb(x, y, 25, 25, 25);
      } else if (y >= 110 && y < 145 && x >= 110 && x < 155) {
        im.setPixelRgb(x, y, 218, 34, 34);
      } else if (y >= 165 && y < 190 && x >= 40 && x < 90) {
        im.setPixelRgb(x, y, 28, 86, 224);
      } else {
        im.setPixelRgb(x, y, 242, 240, 236);
      }
    }
  }
  return img.encodeJpg(im, quality: 94);
}

Uint8List _makeDeskPaperJpeg({int width = 480, int height = 640}) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  final x0 = (width * 0.14).round();
  final x1 = (width * 0.86).round();
  final y0 = (height * 0.10).round();
  final y1 = (height * 0.90).round();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final inPaper = x >= x0 && x <= x1 && y >= y0 && y <= y1;
      final isLine = inPaper && (y - y0) % 50 < 10 && x > x0 + 24 && x < x1 - 24;
      final v = !inPaper ? 45 : (isLine ? 30 : 244);
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return img.encodeJpg(im, quality: 92);
}

Uint8List _makeDoubleSpreadJpeg({int width = 400, int height = 260, double gutterFrac = 0.44}) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  final gx = (width * gutterFrac).round();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dist = (x - gx).abs();
      final gutterDark = dist <= 5 ? (75 + dist * 24) : 242;
      im.setPixelRgb(x, y, gutterDark, gutterDark, gutterDark);
    }
  }
  return img.encodeJpg(im, quality: 92);
}

Uint8List _makeSignaturePng() {
  final im = img.Image(width: 80, height: 32, numChannels: 4);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 80; x++) {
      if (y >= 10 && y <= 20 && x >= 10 && x <= 70) {
        im.setPixelRgba(x, y, 20, 40, 180, 255);
      } else {
        im.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }
  return Uint8List.fromList(img.encodePng(im));
}

class _FakeAcquisition extends ImageAcquisition {
  _FakeAcquisition({required this.supportsCam});
  final bool supportsCam;
  @override
  bool get supportsCamera => supportsCam;
  @override
  Future<List<PickedImageEntry>> retrieveLostEntries() async => const <PickedImageEntry>[];
}

void main() {
  test('引擎留红印章模式（bwStamp）保留红章与蓝签并漂白背景黑字', () {
    const w = 200;
    const h = 240;
    final decoded = img.decodeJpg(_makeStampDocJpeg(width: w, height: h))!;
    final rgba = decoded.convert(format: img.Format.uint8, numChannels: 4, alpha: 255).getBytes(order: img.ChannelOrder.rgba);
    final out = renderPage(
      RgbaSource(data: rgba, width: w, height: h),
      const {'mode': 'bw_stamp', 'shadow': 60, 'contrast': 56},
    );
    expect(out.channels, 4);
    expect(out.format, 'png');

    // 纸面背景应为纯白
    final bgP = (20 * w + 20) * 4;
    expect(out.data[bgP], 255);
    expect(out.data[bgP + 1], 255);
    expect(out.data[bgP + 2], 255);

    // 黑色正文应为纯黑
    final txtP = (48 * w + 60) * 4;
    expect(out.data[txtP], 0);

    // 红色印章保留显著红色
    final redP = (128 * w + 132) * 4;
    expect(out.data[redP] > out.data[redP + 1] + 50, isTrue);
    expect(out.data[redP] > out.data[redP + 2] + 50, isTrue);

    // 蓝色签名保留显著蓝色
    final blueP = (178 * w + 65) * 4;
    expect(out.data[blueP + 2] > out.data[blueP] + 50, isTrue);
  });

  test('引擎去摩尔纹（descreen）平抑彩斑纹理且书缝检测准确', () {
    const w = 64;
    const h = 64;
    final moire = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = (y * w + x) * 4;
        final isAlt = (x + y).isEven;
        moire[p] = isAlt ? 245 : 155;
        moire[p + 1] = isAlt ? 160 : 245;
        moire[p + 2] = 200;
        moire[p + 3] = 255;
      }
    }
    final smoothed = descreenRgba(moire, w, h);
    expect((smoothed[0] - smoothed[4]).abs() < (moire[0] - moire[4]).abs(), isTrue);

    final spread = img.decodeJpg(_makeDoubleSpreadJpeg(gutterFrac: 0.44))!;
    final spreadRgba = spread
        .convert(format: img.Format.uint8, numChannels: 4, alpha: 255)
        .getBytes(order: img.ChannelOrder.rgba);
    final detectedX = detectBookGutterX(spreadRgba, spread.width, spread.height);
    expect((detectedX - 0.44).abs() < 0.05, isTrue);

    final left = cropNormalizedRect(spreadRgba, spread.width, spread.height, 0, 0, detectedX, 1);
    final right = cropNormalizedRect(spreadRgba, spread.width, spread.height, detectedX, 0, 1, 1);
    expect(left.width + right.width, spread.width);
    expect(left.height, spread.height);
  });

  test('PDF 支持页脚页码与中英文双层可搜索隐形文字层', () {
    final stubJpeg = Uint8List.fromList([
      0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
      0xff, 0xc0, 0x00, 0x11, 0x08, 0x04, 0xb0, 0x03, 0x20, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
      0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x3f, 0x00, 0x12, 0x34, 0xff, 0xd9,
    ]);
    final pdf = buildPdf(
      [
        PdfPageInput(
          jpegBytes: stubJpeg,
          width: 800,
          height: 1200,
          ocrLines: const [
            PdfOcrLine(text: 'Contract 2026', left: 0.1, top: 0.1, right: 0.5, bottom: 0.15),
            PdfOcrLine(text: '扫描件合同编号', left: 0.1, top: 0.2, right: 0.6, bottom: 0.26),
          ],
        ),
      ],
      const PdfOptions(
        title: '测试双层PDF',
        showPageNumbers: true,
        embedOcrText: true,
      ),
    );
    final str = latin1.decode(pdf);
    expect(str.startsWith('%PDF-1.4'), isTrue);
    expect(str.contains('/BaseFont /Helvetica'), isTrue);
    expect(str.contains('/Subtype /Type0'), isTrue);
    expect(str.contains('/ToUnicode'), isTrue);
    expect(str.contains('3 Tr'), isTrue);
    expect(str.contains('(1 / 1) Tj'), isTrue);
    expect(str.contains('(Contract 2026) Tj'), isTrue);
    expect(str.trimRight().endsWith('%%EOF'), isTrue);
  });

  test('批注涂白/打码/电子签名/水印合成与 ZIP 批量导出与证件拼版', () async {
    final storage = MemoryAppStorage();
    final jobs = RenderJobs(storage: storage);
    final sigPng = _makeSignaturePng();
    final sigUri = await storage.saveSignatureBytes(sigPng, 'sig_1');
    final sig = SavedSignature(
      id: 'sig_1',
      name: '测试签名',
      uri: sigUri,
      width: 80,
      height: 32,
      createdAt: 1,
    );

    final pageUri = await storage.saveSourceBytes(_makeStampDocJpeg(), 'p1', 'p1.jpg');
    final page = PageItem(
      id: 'p1',
      name: 'p1.jpg',
      createdAt: 1,
      sourceUri: pageUri,
      sourceW: 200,
      sourceH: 240,
      options: ScanOptions.defaults,
      annotations: const PageAnnotations(
        strokes: [
          AnnotationStroke(
            kind: StrokeKind.eraseWhite,
            width: 0.08,
            points: [CornerPoint(0.15, 0.20), CornerPoint(0.75, 0.20)],
          ),
        ],
        signatures: [
          SignaturePlacement(
            signatureId: 'sig_1',
            cx: 0.5,
            cy: 0.75,
            widthRatio: 0.4,
            aspectRatio: 0.4,
          ),
        ],
      ),
    );

    final rendered = await jobs.renderPageTask(page, page.options, signatures: [sig]);
    expect(rendered.bytes.isNotEmpty, isTrue);

    final zipOut = await jobs.exportAllImagesZipTask(
      [page, page.copyWith(id: 'p2')],
      signatures: [sig],
      watermarkText: '内部资料',
    );
    expect(zipOut.pageCount, 2);
    final decodedZip = ZipDecoder().decodeBytes(zipOut.bytes);
    expect(decodedZip.length, 2);

    final cardBytes = await jobs.composeIdCardTask(
      frontBytes: _makeStampDocJpeg(),
      frontOptions: ScanOptions.defaults.copyWith(mode: ScanMode.color),
      backBytes: _makeStampDocJpeg(),
      backOptions: ScanOptions.defaults.copyWith(mode: ScanMode.color),
      template: IdCardTemplate.idCard,
      watermarkText: '仅供核验',
    );
    final cardImg = img.decodeJpg(cardBytes)!;
    expect(cardImg.width, 1654);
    expect(cardImg.height, 2339);
  });

  test('IoAppStorage 多文档库、偏好、自定义预设与签名持久化及旧版迁移', () async {
    final tempRoot = await Directory.systemTemp.createTemp('saomiao_lib_test_');
    addTearDown(() async {
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });
    final docsDir = await Directory(p.join(tempRoot.path, 'docs')).create(recursive: true);
    final cacheDir = await Directory(p.join(tempRoot.path, 'tmp')).create(recursive: true);

    final storage = IoAppStorage(
      documentsDirProvider: () async => docsDir,
      tempDirProvider: () async => cacheDir,
    );

    // 模拟旧版仅存 pages.json 自动迁移为 DocumentLibrary
    final uri = await storage.saveSourceBytes(_makeStampDocJpeg(), 'legacy_1', 'legacy.jpg');
    final legacyPage = createPage(
      id: 'legacy_1',
      name: 'legacy.jpg',
      sourceUri: uri,
      sourceW: 200,
      sourceH: 240,
    );
    await storage.savePages([legacyPage]);

    final migratedLib = await storage.loadLibrary();
    expect(migratedLib, isNotNull);
    expect(migratedLib!.documents.length, 1);
    expect(migratedLib.activeDocument.pages.first.id, 'legacy_1');

    // 保存多文档、偏好、预设、签名
    final doc2 = ScanDocument(
      id: 'doc_2',
      title: '租房合同',
      folder: '合同',
      createdAt: 100,
      updatedAt: 200,
    );
    await storage.saveLibrary(
      DocumentLibrary(
        documents: [migratedLib.activeDocument, doc2],
        activeId: 'doc_2',
        customFolders: ['报销'],
      ),
    );
    await storage.savePreferences(const AppPreferences(autoDetectOnImport: false, themeMode: 'dark'));
    await storage.saveCustomPresets(const [
      CustomPreset(id: 'cp_1', name: '我的清晰 preset', patch: {'contrast': 68}),
    ]);
    final sigUri = await storage.saveSignatureBytes(_makeSignaturePng(), 'sig_io');
    await storage.saveSignatures([
      SavedSignature(
        id: 'sig_io',
        name: '张三',
        uri: sigUri,
        width: 80,
        height: 32,
        createdAt: 1,
      ),
    ]);

    final reloaded = IoAppStorage(
      documentsDirProvider: () async => docsDir,
      tempDirProvider: () async => cacheDir,
    );
    final lib2 = await reloaded.loadLibrary();
    expect(lib2!.documents.length, 2);
    expect(lib2.activeId, 'doc_2');
    expect(lib2.allFolders.contains('报销'), isTrue);
    final prefs2 = await reloaded.loadPreferences();
    expect(prefs2.autoDetectOnImport, isFalse);
    expect(prefs2.themeMode, 'dark');
    expect((await reloaded.loadCustomPresets()).first.name, '我的清晰 preset');
    expect((await reloaded.loadSignatures()).first.name, '张三');
  });

  test('ScannerController：导入自动裁边、撤销/重做、多文档切换合并、双页拆页、OCR 与双层导出', () async {
    final exportedFiles = <({String fileName, Uint8List bytes, String mimeType})>[];
    final controller = ScannerController(
      storage: MemoryAppStorage(),
      exporter: FileExporter(
        saveFile: ({
          required String fileName,
          required Uint8List bytes,
          required String mimeType,
          required String dialogTitle,
        }) async {
          exportedFiles.add((fileName: fileName, bytes: bytes, mimeType: mimeType));
          return fileName;
        },
        share: (_) async => const ShareResult('ok', ShareResultStatus.success),
      ),
      ocr: OcrService(
        handler: (bytes, w, h) async => const OcrPageResult(
          text: '甲方：测试公司\n金额：1000元',
          lines: [
            PdfOcrLine(text: '甲方：测试公司', left: 0.1, top: 0.1, right: 0.6, bottom: 0.16),
            PdfOcrLine(text: '金额：1000元', left: 0.1, top: 0.2, right: 0.5, bottom: 0.26),
          ],
          updatedAt: 1,
        ),
      ),
    );
    await controller.init();

    // 导入 480x640 深底白纸图片，应触发导入自动裁边
    await controller.importPickedImages([
      PickedImageInput(name: 'desk_doc.jpg', bytes: _makeDeskPaperJpeg()),
    ]);
    expect(controller.pages.length, 1);
    expect(controller.pages.first.options.corners, isNotNull);

    // 旋转 + 撤销 + 重做
    controller.rotatePage(controller.pages.first);
    expect(controller.pages.first.options.rotate, 90);
    expect(controller.canUndo, isTrue);
    controller.undo();
    expect(controller.pages.first.options.rotate, 0);
    expect(controller.canRedo, isTrue);
    controller.redo();
    expect(controller.pages.first.options.rotate, 90);

    // OCR 识字 + 编辑 + 双层 PDF & TXT 导出
    final ocrRes = await controller.recognizePageOcr(controller.pages.first);
    expect(ocrRes!.lines.length, 2);
    controller.updatePageOcrText(controller.pages.first.id, '甲方：测试公司\n金额：2000元');
    expect(controller.pages.first.ocr!.text, contains('2000元'));

    await controller.exportPdf(
      pdfOptions: const PdfOptions(showPageNumbers: true, embedOcrText: true),
      allPages: true,
      destination: ExportDestination.save,
      customFileName: '我的合同',
    );
    expect(exportedFiles.last.fileName, startsWith('我的合同_'));
    final pdfText = latin1.decode(exportedFiles.last.bytes);
    expect(pdfText.contains('/ToUnicode'), isTrue);

    await controller.exportOcrText(
      allPages: true,
      destination: ExportDestination.save,
      baseName: '识字结果',
    );
    expect(exportedFiles.last.mimeType, 'text/plain');
    expect(utf8.decode(exportedFiles.last.bytes), contains('2000元'));

    // 双页拆页
    await controller.importPickedImages(
      [PickedImageInput(name: 'spread.jpg', bytes: _makeDoubleSpreadJpeg())],
      skipAutoDetect: true,
    );
    final spreadPage = controller.pages.last;
    await controller.splitDoublePage(spreadPage, 0.44, keepOriginal: false);
    expect(controller.pages.length, 3); // desk_doc + 左页 + 右页

    // 多文档创建、切换与合并
    final firstDocId = controller.currentDocument.id;
    await controller.createDocument(title: '第二份文档', folder: '票据');
    expect(controller.documents.length, 2);
    expect(controller.pages, isEmpty);
    controller.mergeDocumentIntoCurrent(firstDocId);
    expect(controller.pages.length, 3);

    // 删除页可撤销（原图不丢失）
    final toDel = controller.pages.first;
    controller.removePage(toDel);
    expect(controller.pages.length, 2);
    controller.undo();
    expect(controller.pages.length, 3);
    expect(await controller.readSourceBytes(controller.pages.first), isNotEmpty);

    controller.dispose();
  });

  testWidgets('深色模式、文档库抽屉、新增预设与导出面板在窄屏下无溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = ScannerController(
      storage: MemoryAppStorage(),
      acquisition: _FakeAcquisition(supportsCam: false),
    );
    addTearDown(controller.dispose);

    await controller.updatePreferences(const AppPreferences(themeMode: 'dark'));
    await tester.pumpWidget(SaomiaoApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await controller.importPickedImages(
        [PickedImageInput(name: 'd1.jpg', bytes: _makeStampDocJpeg())],
        skipAutoDetect: true,
      );
    });
    await tester.pumpAndSettle();

    // 打开文档库并新建文档
    await tester.tap(find.text('默认文档'));
    await tester.pumpAndSettle();
    expect(find.text('扫描文档库'), findsOneWidget);
    await tester.tap(find.text('新建文档'));
    await tester.pumpAndSettle();
    expect(find.text('新建扫描文档'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 关闭文档库 sheet
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // 切换风格面板到「留红印章」
    await tester.tap(find.text('风格'));
    await tester.pumpAndSettle();
    expect(find.text('留红印章'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('留红印章'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(controller.currentPage?.options.mode, ScanMode.bwStamp);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 打开导出抽屉检查新选项
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    expect(find.text('清晰度与体积'), findsOneWidget);
    expect(find.text('显示页脚页码'), findsOneWidget);
    expect(find.text('添加防盗用斜向水印'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
