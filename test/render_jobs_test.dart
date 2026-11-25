import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:saomiao_flutter/engine/options.dart';
import 'package:saomiao_flutter/engine/pdf.dart';
import 'package:saomiao_flutter/io/app_storage.dart';
import 'package:saomiao_flutter/jobs/render_jobs.dart';
import 'package:saomiao_flutter/state/page_models.dart';

Uint8List _makeSolidJpeg(int w, int h, int luma) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, luma, luma, luma);
    }
  }
  return img.encodeJpg(im, quality: 90);
}

class _CountingStorage extends MemoryAppStorage {
  int cachedCount = 0;
  bool failCacheWrite = false;
  final Set<String> keys = <String>{};

  @override
  Future<void> writeCached(
    String key,
    Uint8List bytes,
    String ext,
    int width,
    int height,
  ) async {
    if (failCacheWrite) {
      throw StateError('disk full');
    }
    await super.writeCached(key, bytes, ext, width, height);
    keys.add(key);
    cachedCount = keys.length;
  }

  @override
  Future<void> pruneCached(int keep) async {
    await super.pruneCached(keep);
    if (keys.length > keep) {
      final keepList = keys.skip(keys.length - keep).toSet();
      keys
        ..clear()
        ..addAll(keepList);
      cachedCount = keys.length;
    }
  }
}

void main() {
  test('sha256Hex 与标准向量一致且指纹防碰撞', () {
    expect(
      sha256Hex(utf8.encode('')),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );

    final p10 = createPage(
      id: 'p1',
      name: 'a.jpg',
      sourceUri: 'orig/p1.jpg',
      sourceW: 10,
      sourceH: 20,
    );
    final p13 = createPage(
      id: 'p2',
      name: 'b.jpg',
      sourceUri: 'orig/p2.jpg',
      sourceW: 13,
      sourceH: 20,
    );
    final fp1 = computeRenderFingerprint(p10, ScanOptions.defaults, 'image/png', 0.92);
    final fp2 = computeRenderFingerprint(p13, ScanOptions.defaults, 'image/png', 0.92);
    expect(fp1.length, 64);
    expect(fp1, isNot(equals(fp2)));
  });

  test('renderPageTask 持续执行 30 条缓存裁剪并容忍缓存写失败', () async {
    final storage = _CountingStorage();
    final jobs = RenderJobs(storage: storage);

    for (var i = 0; i < 35; i++) {
      final bytes = _makeSolidJpeg(10 + i, 12, 200);
      final uri = await storage.saveSourceBytes(bytes, 'pg_$i', 'pg_$i.jpg');
      final page = createPage(
        id: 'pg_$i',
        name: 'pg_$i.jpg',
        sourceUri: uri,
        sourceW: 10 + i,
        sourceH: 12,
      );
      final res = await jobs.renderPageTask(page, page.options);
      expect(res.width, 10 + i);
      expect(storage.cachedCount <= 30, isTrue);
    }
    expect(storage.cachedCount, 30);

    // 缓存写异常不影响已渲染返回
    storage.failCacheWrite = true;
    final uriErr = await storage.saveSourceBytes(_makeSolidJpeg(18, 18, 220), 'pg_err', 'err.jpg');
    final errPage = createPage(
      id: 'pg_err',
      name: 'err.jpg',
      sourceUri: uriErr,
      sourceW: 18,
      sourceH: 18,
    );
    final ok = await jobs.exportImageTask(errPage, errPage.options);
    expect(ok.width, 18);
  });

  test('exportPdfTask 遇到损坏页时明确指出页码与文件名', () async {
    final storage = MemoryAppStorage();
    final jobs = RenderJobs(storage: storage);
    final goodUri = await storage.saveSourceBytes(_makeSolidJpeg(40, 50, 220), 'p1', 'good.jpg');
    final badUri = await storage.saveSourceBytes(Uint8List.fromList([0, 1, 2]), 'p2', 'bad.jpg');

    final p1 = createPage(id: 'p1', name: 'good.jpg', sourceUri: goodUri, sourceW: 40, sourceH: 50);
    final p2 = createPage(id: 'p2', name: 'bad.jpg', sourceUri: badUri, sourceW: 40, sourceH: 50);

    expect(
      () => jobs.exportPdfTask([p1, p2], const PdfOptions()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('第 2 页'), contains('bad.jpg')),
        ),
      ),
    );
  });
}
