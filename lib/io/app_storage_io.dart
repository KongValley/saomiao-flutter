import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../state/page_models.dart';
import 'app_storage.dart';

class IoAppStorage implements AppStorage {
  static const String _rootFolder = 'saomiao-scan';
  static final RegExp _cacheNameRe =
      RegExp(r'^cache_([a-z0-9]+)_(\d+)x(\d+)\.(jpg|png)$', caseSensitive: false);

  Directory? _docRoot;
  Directory? _origDir;
  Directory? _cacheRenderDir;
  Directory? _exportDir;

  @override
  bool get isPersistent => true;

  Future<void> _ensureDirs() async {
    if (_docRoot != null) return;
    final docs = await getApplicationDocumentsDirectory();
    final temp = await getTemporaryDirectory();
    final root = Directory(p.join(docs.path, _rootFolder));
    final orig = Directory(p.join(root.path, 'orig'));
    final cacheRender = Directory(p.join(temp.path, _rootFolder, 'render'));
    final exportDir = Directory(p.join(temp.path, _rootFolder, 'export'));
    await root.create(recursive: true);
    await orig.create(recursive: true);
    await cacheRender.create(recursive: true);
    await exportDir.create(recursive: true);
    _docRoot = root;
    _origDir = orig;
    _cacheRenderDir = cacheRender;
    _exportDir = exportDir;
  }

  String _extensionOf(String? fileName) {
    if (fileName == null || fileName.isEmpty) return '.jpg';
    final ext = p.extension(fileName).toLowerCase();
    if (const ['.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.bmp'].contains(ext)) {
      return ext == '.jpeg' ? '.jpg' : ext;
    }
    return '.jpg';
  }

  File _resolveFile(String uriOrPath) {
    if (uriOrPath.startsWith('file://')) {
      return File.fromUri(Uri.parse(uriOrPath));
    }
    return File(uriOrPath);
  }

  @override
  Future<List<PageItem>> loadPages() async {
    try {
      await _ensureDirs();
      final metaFile = File(p.join(_docRoot!.path, 'pages.json'));
      if (!await metaFile.exists()) return const <PageItem>[];
      final rawText = await metaFile.readAsString();
      final decoded = jsonDecode(rawText);
      if (decoded is! List) return const <PageItem>[];
      final out = <PageItem>[];
      for (final row in decoded) {
        final item = PageItem.tryFromJson(row);
        if (item == null) continue;
        final srcFile = _resolveFile(item.sourceUri);
        if (!await srcFile.exists()) continue;
        out.add(item);
      }
      return out;
    } catch (_) {
      return const <PageItem>[];
    }
  }

  @override
  Future<void> savePages(List<PageItem> pages) async {
    await _ensureDirs();
    final metaFile = File(p.join(_docRoot!.path, 'pages.json'));
    final tmpFile = File(p.join(_docRoot!.path, 'pages.json.tmp'));
    final jsonText = jsonEncode(pages.map((p) => p.toJson()).toList(growable: false));
    await tmpFile.writeAsString(jsonText, flush: true);
    if (await metaFile.exists()) {
      await metaFile.delete();
    }
    await tmpFile.rename(metaFile.path);
  }

  @override
  Future<String> saveSourceBytes(
    Uint8List bytes,
    String pageId,
    String? fileName,
  ) async {
    await _ensureDirs();
    final ext = _extensionOf(fileName);
    final target = File(p.join(_origDir!.path, '$pageId$ext'));
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  @override
  Future<Uint8List> readSourceBytes(String sourceUri) async {
    try {
      final file = _resolveFile(sourceUri);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('图片无法解析：原图为空');
      }
      return bytes;
    } catch (_) {
      throw StateError('图片无法解析：读取原图失败');
    }
  }

  @override
  Future<void> deleteSource(String sourceUri) async {
    try {
      final file = _resolveFile(sourceUri);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 删除失败不阻断主流程
    }
  }

  @override
  Future<CachedRenderEntry?> findCached(String key) async {
    try {
      await _ensureDirs();
      final prefix = 'cache_${key}_';
      await for (final entity in _cacheRenderDir!.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(prefix)) continue;
        final match = _cacheNameRe.firstMatch(name);
        if (match == null) continue;
        final bytes = await entity.readAsBytes();
        if (bytes.isEmpty) continue;
        return CachedRenderEntry(
          bytes: bytes,
          width: int.tryParse(match.group(2)!) ?? 0,
          height: int.tryParse(match.group(3)!) ?? 0,
          format: match.group(4)!.toLowerCase() == 'png' ? 'png' : 'jpeg',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeCached(
    String key,
    Uint8List bytes,
    String ext,
    int width,
    int height,
  ) async {
    if (!RegExp(r'^[a-z0-9]{1,32}$', caseSensitive: false).hasMatch(key)) {
      return;
    }
    if (bytes.isEmpty) return;
    await _ensureDirs();
    final safeW = width < 1 ? 1 : width;
    final safeH = height < 1 ? 1 : height;
    final file = File(p.join(_cacheRenderDir!.path, 'cache_${key}_${safeW}x$safeH.$ext'));
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> pruneCached(int keep) async {
    try {
      await _ensureDirs();
      final entries = <({File file, DateTime modified})>[];
      await for (final entity in _cacheRenderDir!.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        entries.add((file: entity, modified: stat.modified));
      }
      entries.sort((a, b) => b.modified.compareTo(a.modified));
      for (final item in entries.skip(keep < 0 ? 0 : keep)) {
        try {
          await item.file.delete();
        } catch (_) {
          // 跳过不可删文件
        }
      }
    } catch (_) {
      // 忽略裁剪错误
    }
  }

  @override
  Future<String?> writeExportTempFile(Uint8List bytes, String fileName) async {
    await _ensureDirs();
    final file = File(p.join(_exportDir!.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

AppStorage createPlatformStorage() => IoAppStorage();
