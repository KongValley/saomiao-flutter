import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:saomiao_flutter/engine/pdf.dart';
import 'package:saomiao_flutter/io/app_storage.dart';
import 'package:saomiao_flutter/io/image_acquisition.dart';
import 'package:saomiao_flutter/jobs/render_jobs.dart';
import 'package:saomiao_flutter/main.dart';
import 'package:saomiao_flutter/state/page_models.dart';
import 'package:saomiao_flutter/state/scanner_controller.dart';

Uint8List _makeSampleJpeg({int width = 160, int height = 200}) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final isDark = y > 40 && y < 56 && x > 24 && x < width - 24;
      final v = isDark ? 25 : 242;
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return img.encodeJpg(im, quality: 90);
}

class _FakeAcquisition extends ImageAcquisition {
  _FakeAcquisition({required this.supportsCam});

  final bool supportsCam;

  @override
  bool get supportsCamera => supportsCam;
}

void main() {
  testWidgets('空状态渲染（窄屏手机视口）无溢出并展示核心入口', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = ScannerController(
      storage: MemoryAppStorage(),
      acquisition: _FakeAcquisition(supportsCam: true),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(SaomiaoApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('扫描件工坊'), findsOneWidget);
    expect(find.text('不上传'), findsOneWidget);
    expect(find.text('把纸变成扫描件'), findsOneWidget);
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('从相册选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导入图片后完整渲染链路、底部抽屉切换与四角覆盖层可用', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final storage = MemoryAppStorage();
    final controller = ScannerController(
      storage: storage,
      acquisition: _FakeAcquisition(supportsCam: true),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(SaomiaoApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await controller.importPickedImages([
        PickedImageInput(name: 'doc1.jpg', bytes: _makeSampleJpeg()),
      ]);
    });
    await tester.pumpAndSettle();

    expect(find.text('第 1 / 共 1 页'), findsOneWidget);
    expect(find.text('四角'), findsOneWidget);
    expect(find.text('风格'), findsOneWidget);
    expect(find.text('参数'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);

    // 打开风格抽屉并切换为灰度
    await tester.tap(find.text('风格'));
    await tester.pumpAndSettle();
    expect(find.text('扫描风格'), findsNWidgets(2)); // title + section
    expect(find.text('文档'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('灰度'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(controller.currentPage?.options.mode.value, 'gray');

    // 关闭抽屉
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 打开参数抽屉
    await tester.tap(find.text('参数'));
    await tester.pumpAndSettle();
    expect(find.text('参数调整'), findsOneWidget);
    expect(find.text('自动纠偏'), findsOneWidget);
    expect(find.text('反相显示'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 打开导出抽屉
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    expect(find.text('导出扫描件'), findsOneWidget);
    expect(find.text('导出 PDF'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 打开四角校正覆盖层
    await tester.tap(find.text('四角'));
    await tester.pumpAndSettle();
    expect(find.text('四角校正'), findsOneWidget);
    expect(find.text('自动检测'), findsOneWidget);
    expect(find.text('应用'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面宽屏（1280×720）自适应双栏布局正常渲染', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = ScannerController(
      storage: MemoryAppStorage(),
      acquisition: _FakeAcquisition(supportsCam: false),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(SaomiaoApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await controller.importPickedImages([
        PickedImageInput(name: 'desktop_doc.jpg', bytes: _makeSampleJpeg()),
      ]);
    });
    await tester.pumpAndSettle();

    expect(find.text('四角透视校正'), findsOneWidget);
    expect(find.text('第 1 / 共 1 页'), findsOneWidget);
    expect(find.text('文档'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('RenderJobs.exportPdfTask：真实图像管线编码 JPEG 并产出合法多页 PDF', () async {
    final storage = MemoryAppStorage();
    final jobs = RenderJobs(storage: storage);
    final jpegBytes = _makeSampleJpeg();
    final uri1 = await storage.saveSourceBytes(jpegBytes, 'p1', 'p1.jpg');
    final uri2 = await storage.saveSourceBytes(jpegBytes, 'p2', 'p2.jpg');

    final p1 = createPage(id: 'p1', name: 'p1.jpg', sourceUri: uri1, sourceW: 160, sourceH: 200);
    final p2 = createPage(id: 'p2', name: 'p2.jpg', sourceUri: uri2, sourceW: 160, sourceH: 200);

    final out = await jobs.exportPdfTask([p1, p2], const PdfOptions());
    expect(out.pageCount, 2);
    final pdfStr = latin1.decode(out.bytes);
    expect(pdfStr.startsWith('%PDF-1.4'), isTrue);
    expect(pdfStr.contains('/Count 2 '), isTrue);
    expect(pdfStr.trimRight().endsWith('%%EOF'), isTrue);
  });
}
