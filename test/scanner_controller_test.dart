import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:saomiao_flutter/engine/options.dart';
import 'package:saomiao_flutter/engine/pdf.dart';
import 'package:saomiao_flutter/io/app_storage.dart';
import 'package:saomiao_flutter/io/file_export.dart';
import 'package:saomiao_flutter/io/image_acquisition.dart';
import 'package:saomiao_flutter/state/page_models.dart';
import 'package:saomiao_flutter/state/scanner_controller.dart';
import 'package:share_plus/share_plus.dart';

Uint8List _makeSampleJpeg({int width = 80, int height = 100, int luma = 230}) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = (y > 20 && y < 30 && x > 10 && x < width - 10) ? 20 : luma;
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return img.encodeJpg(im, quality: 90);
}

class _DelayedPersistStorage extends MemoryAppStorage {
  _DelayedPersistStorage({this.loadCompleter});

  final Completer<List<PageItem>>? loadCompleter;
  int saveCalls = 0;
  List<PageItem> lastSaved = const <PageItem>[];

  @override
  bool get isPersistent => true;

  @override
  Future<List<PageItem>> loadPages() async {
    if (loadCompleter != null) {
      return loadCompleter!.future;
    }
    return super.loadPages();
  }

  @override
  Future<void> savePages(List<PageItem> pages) async {
    saveCalls++;
    lastSaved = List<PageItem>.of(pages);
    await super.savePages(pages);
  }
}

class _FakeLostAcquisition extends ImageAcquisition {
  _FakeLostAcquisition(this.lost);

  final List<PickedImageEntry> lost;

  @override
  bool get supportsCamera => false;

  @override
  Future<List<PickedImageEntry>> retrieveLostEntries() async => lost;
}

class _ControlledReadStorage extends MemoryAppStorage {
  final Set<String> blockedUris = <String>{};
  final Map<String, Completer<Uint8List>> pendingReads = <String, Completer<Uint8List>>{};

  @override
  Future<Uint8List> readSourceBytes(String sourceUri) async {
    if (blockedUris.contains(sourceUri)) {
      final completer = Completer<Uint8List>();
      pendingReads[sourceUri] = completer;
      return completer.future;
    }
    return super.readSourceBytes(sourceUri);
  }
}

void main() {
  test('启动期间导入不会在 init 完成后丢失且能正确落盘', () async {
    final loadCompleter = Completer<List<PageItem>>();
    final storage = _DelayedPersistStorage(loadCompleter: loadCompleter);
    final existingUri = await storage.saveSourceBytes(_makeSampleJpeg(), 'old', 'old.jpg');
    final existing = createPage(
      id: 'old',
      name: 'old.jpg',
      sourceUri: existingUri,
      sourceW: 80,
      sourceH: 100,
    );

    final controller = ScannerController(storage: storage);
    final initFuture = controller.init();

    // 在 init 尚未完成时导入新页
    final importFuture = controller.importPickedImages([
      PickedImageInput(name: 'early.jpg', bytes: _makeSampleJpeg()),
    ]);

    loadCompleter.complete([existing]);
    await Future.wait([initFuture, importFuture]);
    await controller.flushPersist();

    expect(controller.pages.map((p) => p.name), ['old.jpg', 'early.jpg']);
    expect(storage.lastSaved.length, 2);
    controller.dispose();
  });

  test('dispose 会刷新未落盘的防抖编辑且 Android retrieveLostEntries 可在启动恢复', () async {
    final lostBytes = _makeSampleJpeg();
    final storage = _DelayedPersistStorage();
    final acq = _FakeLostAcquisition([
      PickedImageEntry(
        name: 'lost.jpg',
        readLength: () async => lostBytes.length,
        readBytes: () async => lostBytes,
      ),
    ]);

    final controller = ScannerController(storage: storage, acquisition: acq);
    await controller.init(
      demoPages: [
        createPage(id: 'demo', name: 'demo.jpg', sourceUri: 'mem://demo', sourceW: 80, sourceH: 100),
      ],
    );
    expect(controller.pages.map((p) => p.name), ['lost.jpg']);

    // 在 500ms 防抖窗口内直接 dispose
    controller.applyOptions({'contrast': 77}, immediate: false);
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(storage.lastSaved.length, 1);
    expect(storage.lastSaved.first.options.contrast, 77);
  });

  test('滑杆防抖期间切换页面不会丢弃目标页渲染', () async {
    final controller = ScannerController(storage: MemoryAppStorage());
    await controller.init();
    await controller.importPickedImages([
      PickedImageInput(name: 'p1.jpg', bytes: _makeSampleJpeg(luma: 210)),
      PickedImageInput(name: 'p2.jpg', bytes: _makeSampleJpeg(luma: 240)),
    ]);

    controller.selectPage(0);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 对第 1 页触发 200ms 防抖编辑，然后立即切换到第 2 页
    controller.applyOptions({'contrast': 82}, immediate: false);
    controller.selectPage(1);

    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(controller.currentIndex, 1);
    expect(controller.currentRender, isNotNull);
    expect(controller.currentError, isNull);
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });

  test('applyOptionsToAll 后修改单页旋转再撤销，应保留旋转几何参数', () async {
    final controller = ScannerController(storage: MemoryAppStorage());
    await controller.init();
    await controller.importPickedImages([
      PickedImageInput(name: 'p1.jpg', bytes: _makeSampleJpeg()),
      PickedImageInput(name: 'p2.jpg', bytes: _makeSampleJpeg()),
    ]);

    controller.selectPage(0);
    controller.applyOptions({'mode': 'gray', 'contrast': 72}, immediate: true);
    controller.applyOptionsToAll();
    expect(controller.pages[1].options.mode, ScanMode.gray);

    controller.rotatePage(controller.pages[1]);
    expect(controller.pages[1].options.rotate, 90);

    controller.undoApplyAll();
    expect(controller.pages[1].options.mode, ScanMode.bw);
    expect(controller.pages[1].options.rotate, 90);
    controller.dispose();
  });

  test('超大文件在 readAsBytes 前拒绝、坏文件拒绝入库、导出中禁止删页', () async {
    var readCalled = false;
    final controller = ScannerController(
      storage: MemoryAppStorage(),
      exporter: FileExporter(
        share: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return const ShareResult('ok', ShareResultStatus.success);
        },
      ),
    );
    await controller.init();

    await controller.importPickedEntries([
      PickedImageEntry(
        name: 'huge.jpg',
        readLength: () async => kMaxImportFileBytes + 1,
        readBytes: () async {
          readCalled = true;
          return Uint8List(0);
        },
      ),
      PickedImageEntry(
        name: 'corrupt.bin',
        readLength: () async => 3,
        readBytes: () async => Uint8List.fromList([1, 2, 3]),
      ),
    ]);
    expect(readCalled, isFalse);
    expect(controller.pages, isEmpty);

    await controller.importPickedImages([
      PickedImageInput(name: 'ok.jpg', bytes: _makeSampleJpeg()),
    ]);
    expect(controller.pages.length, 1);

    final exportFuture = controller.exportPdf(
      pdfOptions: const PdfOptions(),
      allPages: true,
      destination: ExportDestination.share,
    );
    controller.removePage(controller.pages.first);
    expect(controller.pages.length, 1);
    await exportFuture;
    controller.dispose();
  });

  test('超过 12 页时内存渲染缓存上限生效且缩略图不丢失', () async {
    final controller = ScannerController(storage: MemoryAppStorage());
    await controller.init();
    final inputs = List<PickedImageInput>.generate(
      14,
      (i) => PickedImageInput(name: 'p_$i.jpg', bytes: _makeSampleJpeg(width: 60 + i, height: 80)),
    );
    await controller.importPickedImages(inputs);
    for (var i = 0; i < 14; i++) {
      controller.selectPage(i);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    var fullInMemory = 0;
    for (final p in controller.pages) {
      expect(controller.thumbnailOf(p.id), isNotNull);
      if (controller.renderOf(p.id) != null) fullInMemory++;
    }
    expect(fullInMemory <= 12, isTrue);
    controller.dispose();
  });

  test('删除正在渲染的页面会取消渲染并清除忙碌态，且不弹出过期错误提示', () async {
    final storage = _ControlledReadStorage();
    final controller = ScannerController(storage: storage);
    final toasts = <ToastMessage>[];
    final sub = controller.toasts.listen(toasts.add);
    addTearDown(sub.cancel);

    await controller.init();
    await controller.importPickedImages([
      PickedImageInput(name: 'p1.jpg', bytes: _makeSampleJpeg(luma: 210)),
      PickedImageInput(name: 'p2.jpg', bytes: _makeSampleJpeg(luma: 240)),
    ]);

    // p2 已完成渲染缓存；阻塞 p1 的下次读取后切回 p1
    final p1 = controller.pages[0];
    final p2 = controller.pages[1];
    expect(controller.renderOf(p2.id), isNotNull);

    toasts.clear();
    storage.blockedUris.add(p1.sourceUri);
    controller.selectPage(0);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isBusy, isTrue);

    // 在 p1 仍在读取原图时删除 p1，切换到已缓存的 p2
    controller.removePage(p1);
    expect(controller.pages.map((p) => p.id), [p2.id]);
    expect(controller.isBusy, isFalse);

    // 模拟被删页面的在途读取随后失败
    storage.pendingReads[p1.sourceUri]!.completeError(StateError('图片无法解析：读取原图失败'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.errorOf(p1.id), isNull);
    expect(controller.currentError, isNull);
    expect(toasts.where((t) => t.kind == ToastKind.error), isEmpty);
    controller.dispose();
  });

  test('切到已缓存页时会取消上一页在途渲染且不残留错误提示', () async {
    final storage = _ControlledReadStorage();
    final controller = ScannerController(storage: storage);
    final toasts = <ToastMessage>[];
    final sub = controller.toasts.listen(toasts.add);
    addTearDown(sub.cancel);

    await controller.init();
    await controller.importPickedImages([
      PickedImageInput(name: 'p1.jpg', bytes: _makeSampleJpeg(luma: 210)),
      PickedImageInput(name: 'p2.jpg', bytes: _makeSampleJpeg(luma: 240)),
    ]);

    final p1 = controller.pages[0];
    storage.blockedUris.add(p1.sourceUri);
    controller.selectPage(0);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isBusy, isTrue);

    toasts.clear();
    controller.selectPage(1);
    expect(controller.currentIndex, 1);
    expect(controller.isBusy, isFalse);

    storage.pendingReads[p1.sourceUri]!.completeError(StateError('图片无法解析：读取原图失败'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.errorOf(p1.id), isNull);
    expect(toasts.where((t) => t.kind == ToastKind.error), isEmpty);
    controller.dispose();
  });
}
