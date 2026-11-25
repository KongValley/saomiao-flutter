import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saomiao_flutter/engine/options.dart';
import 'package:saomiao_flutter/io/app_storage_io.dart';
import 'package:saomiao_flutter/state/page_models.dart';

void main() {
  late Directory tempRoot;
  late Directory docsDir;
  late Directory cacheDir;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('saomiao_io_test_');
    docsDir = await Directory(p.join(tempRoot.path, 'docs')).create(recursive: true);
    cacheDir = await Directory(p.join(tempRoot.path, 'tmp')).create(recursive: true);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  IoAppStorage makeStorage([Directory? overrideDocs]) {
    return IoAppStorage(
      documentsDirProvider: () async => overrideDocs ?? docsDir,
      tempDirProvider: () async => cacheDir,
    );
  }

  test('savePages：原子替换、并发串行与中断恢复（.bak / .tmp）', () async {
    final storage = makeStorage();
    final uri = await storage.saveSourceBytes(
      Uint8List.fromList([1, 2, 3, 4]),
      'pg_1',
      'doc1.jpg',
    );
    expect(uri, 'orig/pg_1.jpg');

    final page1 = createPage(
      id: 'pg_1',
      name: 'doc1.jpg',
      sourceUri: uri,
      sourceW: 100,
      sourceH: 120,
    );

    // 并发多次保存不应竞争同一临时文件
    await Future.wait([
      storage.savePages([page1]),
      storage.savePages([page1.copyWith(name: 'doc1_v2.jpg')]),
      storage.savePages([page1.copyWith(name: 'doc1_v3.jpg')]),
    ]);

    final loaded = await storage.loadPages();
    expect(loaded.length, 1);

    // 模拟崩溃在 delete/rename 之间：pages.json 缺失但 pages.json.bak 存在
    final scanRoot = p.join(docsDir.path, 'saomiao-scan');
    final meta = File(p.join(scanRoot, 'pages.json'));
    final bak = File(p.join(scanRoot, 'pages.json.bak'));
    await meta.rename(bak.path);
    expect(await meta.exists(), isFalse);

    final recoveredFromBak = await makeStorage().loadPages();
    expect(recoveredFromBak.length, 1);
    expect(recoveredFromBak.first.id, 'pg_1');
    expect(await meta.exists(), isTrue);

    // 模拟主索引损坏且仅存 staged .tmp 文件
    await meta.writeAsString('{broken json');
    await File(p.join(scanRoot, 'pages.json.tmp.99'))
        .writeAsString('[${_encodeSinglePageJson(page1.copyWith(name: 'from_tmp.jpg'))}]');
    final recoveredFromTmp = await makeStorage().loadPages();
    expect(recoveredFromTmp.length, 1);
    expect(recoveredFromTmp.first.name, 'from_tmp.jpg');
  });

  test('目录迁移兼容：旧绝对路径在文档根目录变化后自动迁移到相对路径', () async {
    final oldDocs = await Directory(p.join(tempRoot.path, 'old_docs')).create(recursive: true);
    final newDocs = await Directory(p.join(tempRoot.path, 'new_docs')).create(recursive: true);

    final oldOrigDir = Directory(p.join(oldDocs.path, 'saomiao-scan', 'orig'))
      ..createSync(recursive: true);
    final newRoot = Directory(p.join(newDocs.path, 'saomiao-scan'))..createSync(recursive: true);
    final newOrigDir = Directory(p.join(newRoot.path, 'orig'))..createSync(recursive: true);

    final legacyAbsPath = p.join(oldOrigDir.path, 'pg_legacy.jpg');
    await File(p.join(newOrigDir.path, 'pg_legacy.jpg')).writeAsBytes([9, 8, 7]);

    final legacyPage = PageItem(
      id: 'pg_legacy',
      name: 'legacy.jpg',
      createdAt: 1,
      sourceUri: legacyAbsPath,
      sourceW: 200,
      sourceH: 300,
      options: ScanOptions.defaults,
    );
    await File(p.join(newRoot.path, 'pages.json'))
        .writeAsString('[${_encodeSinglePageJson(legacyPage)}]');

    final migratedStorage = makeStorage(newDocs);
    final loaded = await migratedStorage.loadPages();
    expect(loaded.length, 1);
    expect(loaded.first.sourceUri, 'orig/pg_legacy.jpg');
    expect(await migratedStorage.readSourceBytes(loaded.first.sourceUri), [9, 8, 7]);
  });

  test('writeCached 原子发布与导出临时文件互不覆盖', () async {
    final storage = makeStorage();
    final key = 'a' * 64;
    await storage.writeCached(key, Uint8List.fromList([1, 2, 3]), 'jpg', 100, 120);

    // 插入半写临时文件不应干扰 findCached
    final cacheDirPath = p.join(cacheDir.path, 'saomiao-scan', 'render');
    await File(p.join(cacheDirPath, '.tmp_${key}_1.jpg')).writeAsBytes([99]);

    final hit = await storage.findCached(key);
    expect(hit, isNotNull);
    expect(hit!.bytes, [1, 2, 3]);

    final p1 = await storage.writeExportTempFile(Uint8List.fromList([1, 1]), '扫描件_同分.pdf');
    final p2 = await storage.writeExportTempFile(Uint8List.fromList([2, 2]), '扫描件_同分.pdf');
    expect(p1, isNotNull);
    expect(p2, isNotNull);
    expect(p1, isNot(equals(p2)));
    expect(await File(p1!).readAsBytes(), [1, 1]);
    expect(await File(p2!).readAsBytes(), [2, 2]);
  });

  test('非法 file:// URI 不导致其余页面丢失且兼容旧版 pages.json.tmp 恢复', () async {
    final storage = makeStorage();
    final validUri = await storage.saveSourceBytes(
      Uint8List.fromList([5, 6, 7]),
      'pg_ok',
      'ok.jpg',
    );
    final validPage = createPage(
      id: 'pg_ok',
      name: 'ok.jpg',
      sourceUri: validUri,
      sourceW: 120,
      sourceH: 160,
    );
    final badUriPage = PageItem(
      id: 'pg_bad',
      name: 'bad.jpg',
      createdAt: 1,
      sourceUri: 'file://[%invalid',
      sourceW: 100,
      sourceH: 100,
      options: ScanOptions.defaults,
    );

    final scanRoot = p.join(docsDir.path, 'saomiao-scan');
    final meta = File(p.join(scanRoot, 'pages.json'));
    await meta.writeAsString(jsonEncode([badUriPage.toJson(), validPage.toJson()]));

    final loaded = await makeStorage().loadPages();
    expect(loaded.map((e) => e.id), ['pg_ok']);

    // 删除 pages.json 并写入无时间戳后缀的旧版 pages.json.tmp
    await meta.delete();
    await File(p.join(scanRoot, 'pages.json.tmp'))
        .writeAsString(jsonEncode([validPage.copyWith(name: 'legacy_tmp.jpg').toJson()]));
    final recoveredLegacy = await makeStorage().loadPages();
    expect(recoveredLegacy.length, 1);
    expect(recoveredLegacy.first.name, 'legacy_tmp.jpg');
  });
}

String _encodeSinglePageJson(PageItem item) {
  return jsonEncode(item.toJson());
}
