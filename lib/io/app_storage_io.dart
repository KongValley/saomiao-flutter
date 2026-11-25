import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../state/page_models.dart';
import 'app_storage.dart';

class IoAppStorage implements AppStorage {
  IoAppStorage({
    this._documentsDirProvider,
    this._tempDirProvider,
  });

  static const String _rootFolder = 'saomiao-scan';
  static const String _origRelativePrefix = 'orig/';
  static final RegExp _cacheNameRe =
      RegExp(r'^cache_([a-z0-9]+)_(\d+)x(\d+)\.(jpg|png)$', caseSensitive: false);
  static final RegExp _validKeyRe = RegExp(r'^[a-z0-9]{1,64}$', caseSensitive: false);

  final Future<Directory> Function()? _documentsDirProvider;
  final Future<Directory> Function()? _tempDirProvider;

  Directory? _docRoot;
  Directory? _origDir;
  Directory? _sigDir;
  Directory? _cacheRenderDir;
  Directory? _exportDir;

  Future<void> _saveChain = Future<void>.value();
  int _tmpSeq = 0;

  @override
  bool get isPersistent => true;

  Future<void> _ensureDirs() async {
    if (_docRoot != null) return;
    final docs = await (_documentsDirProvider?.call() ?? getApplicationDocumentsDirectory());
    final temp = await (_tempDirProvider?.call() ?? getTemporaryDirectory());
    final root = Directory(p.join(docs.path, _rootFolder));
    final orig = Directory(p.join(root.path, 'orig'));
    final sig = Directory(p.join(root.path, 'signatures'));
    final cacheRender = Directory(p.join(temp.path, _rootFolder, 'render'));
    final exportDir = Directory(p.join(temp.path, _rootFolder, 'export'));
    await root.create(recursive: true);
    await orig.create(recursive: true);
    await sig.create(recursive: true);
    await cacheRender.create(recursive: true);
    await exportDir.create(recursive: true);
    _docRoot = root;
    _origDir = orig;
    _sigDir = sig;
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

  String _extractBasename(String rawPath) {
    final normalized = rawPath.replaceAll('\\', '/');
    return p.posix.basename(normalized);
  }

  File? _resolvePrimaryFile(String uriOrPath) {
    if (uriOrPath.startsWith('file://')) {
      final parsed = Uri.tryParse(uriOrPath);
      if (parsed == null || !parsed.isScheme('file')) return null;
      try {
        return File.fromUri(parsed);
      } catch (_) {
        return null;
      }
    }
    final normalized = uriOrPath.replaceAll('\\', '/');
    if (normalized.startsWith(_origRelativePrefix)) {
      final rel = normalized.substring(_origRelativePrefix.length);
      return File(p.join(_origDir!.path, rel));
    }
    if (!p.isAbsolute(uriOrPath)) {
      return File(p.join(_docRoot!.path, uriOrPath));
    }
    return File(uriOrPath);
  }

  Future<({File file, String? migratedSourceUri})?> _resolveExistingSource(
    String sourceUri,
  ) async {
    await _ensureDirs();
    final primary = _resolvePrimaryFile(sourceUri);
    final normalized = sourceUri.replaceAll('\\', '/');
    if (primary != null && await primary.exists()) {
      final base = _extractBasename(normalized);
      final inOrig = File(p.join(_origDir!.path, base));
      if (!normalized.startsWith(_origRelativePrefix) &&
          p.equals(p.normalize(primary.path), p.normalize(inOrig.path))) {
        return (file: primary, migratedSourceUri: '$_origRelativePrefix$base');
      }
      return (file: primary, migratedSourceUri: null);
    }

    // Fallback: container root relocated (e.g. iOS container UUID changed or backup restored).
    final base = _extractBasename(normalized);
    if (base.isEmpty || base == '.' || base == '..') return null;
    final relocated = File(p.join(_origDir!.path, base));
    if (await relocated.exists()) {
      return (file: relocated, migratedSourceUri: '$_origRelativePrefix$base');
    }
    return null;
  }

  Future<List<dynamic>?> _tryDecodeIndexFile(File file) async {
    try {
      if (!await file.exists()) return null;
      final rawText = await file.readAsString();
      if (rawText.trim().isEmpty) return null;
      final decoded = jsonDecode(rawText);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupStrayIndexFiles() async {
    try {
      await for (final entity in _docRoot!.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name == 'pages.json.bak' ||
            name == 'pages.json.tmp' ||
            name.startsWith('pages.json.tmp.')) {
          try {
            await entity.delete();
          } catch (_) {
            // Ignore locked temp file cleanup errors.
          }
        }
      }
    } catch (_) {
      // Ignore directory listing errors.
    }
  }

  @override
  Future<List<PageItem>> loadPages() async {
    try {
      await _ensureDirs();
      final metaFile = File(p.join(_docRoot!.path, 'pages.json'));
      final bakFile = File(p.join(_docRoot!.path, 'pages.json.bak'));

      var recovered = false;
      List<dynamic>? decoded = await _tryDecodeIndexFile(metaFile);

      if (decoded == null) {
        decoded = await _tryDecodeIndexFile(bakFile);
        if (decoded != null) recovered = true;
      }

      if (decoded == null) {
        final staged = <({File file, DateTime modified})>[];
        await for (final entity in _docRoot!.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name == 'pages.json.tmp' || name.startsWith('pages.json.tmp.')) {
            final stat = await entity.stat();
            staged.add((file: entity, modified: stat.modified));
          }
        }
        staged.sort((a, b) => b.modified.compareTo(a.modified));
        for (final entry in staged) {
          decoded = await _tryDecodeIndexFile(entry.file);
          if (decoded != null) {
            recovered = true;
            break;
          }
        }
      }

      if (decoded == null) return const <PageItem>[];

      final out = <PageItem>[];
      var migrated = false;
      for (final row in decoded) {
        final item = PageItem.tryFromJson(row);
        if (item == null) continue;
        final resolved = await _resolveExistingSource(item.sourceUri);
        if (resolved == null) continue;
        if (resolved.migratedSourceUri != null) {
          out.add(item.copyWith(sourceUri: resolved.migratedSourceUri));
          migrated = true;
        } else {
          out.add(item);
        }
      }

      if (recovered || migrated) {
        try {
          await savePages(out);
        } catch (_) {
          // Best-effort index recovery/migration persist.
        }
      } else {
        await _cleanupStrayIndexFiles();
      }

      return out;
    } catch (_) {
      return const <PageItem>[];
    }
  }

  Future<Object?> _tryDecodeJsonFile(File file) async {
    try {
      if (!await file.exists()) return null;
      final rawText = await file.readAsString();
      if (rawText.trim().isEmpty) return null;
      return jsonDecode(rawText);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJsonFileAtomic(String fileName, Object payload) async {
    await _ensureDirs();
    final metaFile = File(p.join(_docRoot!.path, fileName));
    final bakFile = File(p.join(_docRoot!.path, '$fileName.bak'));
    final tmpFile = File(p.join(_docRoot!.path, '$fileName.tmp.${++_tmpSeq}'));
    final jsonText = jsonEncode(payload);

    var movedMetaToBak = false;
    try {
      await tmpFile.writeAsString(jsonText, flush: true);
      if (await metaFile.exists()) {
        if (await bakFile.exists()) {
          await bakFile.delete();
        }
        await metaFile.rename(bakFile.path);
        movedMetaToBak = true;
      }
      await tmpFile.rename(metaFile.path);
      if (await bakFile.exists()) {
        try {
          await bakFile.delete();
        } catch (_) {}
      }
    } catch (_) {
      if (movedMetaToBak && !await metaFile.exists() && await bakFile.exists()) {
        try {
          await bakFile.rename(metaFile.path);
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<Object?> _loadJsonFileWithRecovery(String fileName) async {
    await _ensureDirs();
    final metaFile = File(p.join(_docRoot!.path, fileName));
    final bakFile = File(p.join(_docRoot!.path, '$fileName.bak'));
    var decoded = await _tryDecodeJsonFile(metaFile);
    if (decoded != null) return decoded;
    decoded = await _tryDecodeJsonFile(bakFile);
    if (decoded != null) return decoded;
    final staged = <({File file, DateTime modified})>[];
    await for (final entity in _docRoot!.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == '$fileName.tmp' || name.startsWith('$fileName.tmp.')) {
        final stat = await entity.stat();
        staged.add((file: entity, modified: stat.modified));
      }
    }
    staged.sort((a, b) => b.modified.compareTo(a.modified));
    for (final entry in staged) {
      decoded = await _tryDecodeJsonFile(entry.file);
      if (decoded != null) return decoded;
    }
    return null;
  }

  Future<({List<PageItem> pages, bool migrated})> _resolvePageItems(List<dynamic> rawList) async {
    final out = <PageItem>[];
    var migrated = false;
    for (final row in rawList) {
      final item = PageItem.tryFromJson(row);
      if (item == null) continue;
      final resolved = await _resolveExistingSource(item.sourceUri);
      if (resolved == null) continue;
      if (resolved.migratedSourceUri != null) {
        out.add(item.copyWith(sourceUri: resolved.migratedSourceUri));
        migrated = true;
      } else {
        out.add(item);
      }
    }
    return (pages: out, migrated: migrated);
  }

  @override
  Future<DocumentLibrary?> loadLibrary() async {
    try {
      await _ensureDirs();
      final raw = await _loadJsonFileWithRecovery('documents.json');
      if (raw is Map) {
        final rawDocs = raw['documents'];
        if (rawDocs is List) {
          final docs = <ScanDocument>[];
          var migrated = false;
          for (final entry in rawDocs) {
            final parsed = ScanDocument.tryFromJson(entry);
            if (parsed == null) continue;
            final resolved = await _resolvePageItems(
              parsed.pages.map((p) => p.toJson()).toList(growable: false),
            );
            if (resolved.migrated) migrated = true;
            docs.add(parsed.copyWith(pages: List<PageItem>.unmodifiable(resolved.pages)));
          }
          if (docs.isNotEmpty) {
            final activeIdRaw = raw['activeId'];
            final activeId = activeIdRaw is String && docs.any((d) => d.id == activeIdRaw)
                ? activeIdRaw
                : docs.first.id;
            final rawFolders = raw['customFolders'];
            final customFolders = <String>[
              if (rawFolders is List)
                for (final f in rawFolders)
                  if (f is String && f.trim().isNotEmpty) f.trim(),
            ];
            final lib = DocumentLibrary(
              documents: List<ScanDocument>.unmodifiable(docs),
              activeId: activeId,
              customFolders: List<String>.unmodifiable(customFolders),
            );
            if (migrated) {
              try {
                await saveLibrary(lib);
              } catch (_) {}
            }
            return lib;
          }
        }
      }

      // 兼容旧版单文档 pages.json 自动迁移
      final legacyPages = await loadPages();
      if (legacyPages.isEmpty) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      final doc = ScanDocument(
        id: 'doc_default',
        title: '默认文档',
        folder: '默认',
        createdAt: now,
        updatedAt: now,
        pages: legacyPages,
        currentIndex: 0,
      );
      return DocumentLibrary(documents: <ScanDocument>[doc], activeId: doc.id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveLibrary(DocumentLibrary library) {
    final payload = <String, Object?>{
      'activeId': library.activeId,
      'customFolders': library.customFolders,
      'documents': library.documents.map((d) => d.toJson()).toList(growable: false),
    };
    final activePages = List<PageItem>.unmodifiable(library.activeDocument.pages);
    final next = _saveChain.then((_) async {
      await _writeJsonFileAtomic('documents.json', payload);
      await _writePagesAtomic(activePages);
    });
    _saveChain = next.catchError((_) {});
    return next;
  }

  @override
  Future<AppPreferences> loadPreferences() async {
    try {
      final raw = await _loadJsonFileWithRecovery('prefs.json');
      return AppPreferences.tryFromJson(raw);
    } catch (_) {
      return const AppPreferences();
    }
  }

  @override
  Future<void> savePreferences(AppPreferences prefs) {
    final next = _saveChain.then((_) => _writeJsonFileAtomic('prefs.json', prefs.toJson()));
    _saveChain = next.catchError((_) {});
    return next;
  }

  @override
  Future<List<CustomPreset>> loadCustomPresets() async {
    try {
      final raw = await _loadJsonFileWithRecovery('presets.json');
      if (raw is! List) return const <CustomPreset>[];
      final out = <CustomPreset>[];
      for (final item in raw) {
        final p = CustomPreset.tryFromJson(item);
        if (p != null) out.add(p);
      }
      return out;
    } catch (_) {
      return const <CustomPreset>[];
    }
  }

  @override
  Future<void> saveCustomPresets(List<CustomPreset> presets) {
    final payload = presets.map((e) => e.toJson()).toList(growable: false);
    final next = _saveChain.then((_) => _writeJsonFileAtomic('presets.json', payload));
    _saveChain = next.catchError((_) {});
    return next;
  }

  @override
  Future<List<SavedSignature>> loadSignatures() async {
    try {
      await _ensureDirs();
      final raw = await _loadJsonFileWithRecovery('signatures.json');
      if (raw is! List) return const <SavedSignature>[];
      final out = <SavedSignature>[];
      for (final item in raw) {
        final sig = SavedSignature.tryFromJson(item);
        if (sig == null) continue;
        final bytes = await readSignatureBytes(sig.uri);
        if (bytes != null && bytes.isNotEmpty) {
          out.add(sig);
        }
      }
      return out;
    } catch (_) {
      return const <SavedSignature>[];
    }
  }

  @override
  Future<void> saveSignatures(List<SavedSignature> signatures) {
    final payload = signatures.map((e) => e.toJson()).toList(growable: false);
    final next = _saveChain.then((_) => _writeJsonFileAtomic('signatures.json', payload));
    _saveChain = next.catchError((_) {});
    return next;
  }

  @override
  Future<String> saveSignatureBytes(Uint8List pngBytes, String sigId) async {
    await _ensureDirs();
    final rel = 'signatures/$sigId.png';
    final target = File(p.join(_sigDir!.path, '$sigId.png'));
    final tmp = File(p.join(_sigDir!.path, '.tmp_$sigId.${++_tmpSeq}.png'));
    try {
      await tmp.writeAsBytes(pngBytes, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
    return rel;
  }

  @override
  Future<Uint8List?> readSignatureBytes(String uri) async {
    try {
      await _ensureDirs();
      final base = _extractBasename(uri);
      if (base.isEmpty || base == '.' || base == '..') return null;
      final file = File(p.join(_sigDir!.path, base));
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteSignatureBytes(String uri) async {
    try {
      await _ensureDirs();
      final base = _extractBasename(uri);
      if (base.isEmpty || base == '.' || base == '..') return;
      final file = File(p.join(_sigDir!.path, base));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Future<void> savePages(List<PageItem> pages) {
    final snapshot = List<PageItem>.unmodifiable(pages);
    final next = _saveChain.then((_) => _writePagesAtomic(snapshot));
    _saveChain = next.catchError((_) {});
    return next;
  }

  Future<void> _writePagesAtomic(List<PageItem> pages) async {
    await _ensureDirs();
    final metaFile = File(p.join(_docRoot!.path, 'pages.json'));
    final bakFile = File(p.join(_docRoot!.path, 'pages.json.bak'));
    final tmpFile = File(p.join(_docRoot!.path, 'pages.json.tmp.${++_tmpSeq}'));
    final jsonText = jsonEncode(pages.map((item) => item.toJson()).toList(growable: false));

    var movedMetaToBak = false;
    try {
      await tmpFile.writeAsString(jsonText, flush: true);
      if (await metaFile.exists()) {
        if (await bakFile.exists()) {
          await bakFile.delete();
        }
        await metaFile.rename(bakFile.path);
        movedMetaToBak = true;
      }
      await tmpFile.rename(metaFile.path);
      if (await bakFile.exists()) {
        try {
          await bakFile.delete();
        } catch (_) {
          // Ignore stale backup cleanup failure after commit.
        }
      }
    } catch (_) {
      if (movedMetaToBak && !await metaFile.exists() && await bakFile.exists()) {
        try {
          await bakFile.rename(metaFile.path);
        } catch (_) {
          // Keep bakFile intact for startup recovery if rollback rename fails.
        }
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  @override
  Future<String> saveSourceBytes(
    Uint8List bytes,
    String pageId,
    String? fileName,
  ) async {
    await _ensureDirs();
    final ext = _extensionOf(fileName);
    final relPath = '$_origRelativePrefix$pageId$ext';
    final target = File(p.join(_origDir!.path, '$pageId$ext'));
    final tmp = File(p.join(_origDir!.path, '.tmp_$pageId.${++_tmpSeq}$ext'));
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
    return relPath;
  }

  @override
  Future<Uint8List> readSourceBytes(String sourceUri) async {
    try {
      final resolved = await _resolveExistingSource(sourceUri);
      if (resolved == null) {
        throw StateError('图片无法解析：原图不存在');
      }
      final bytes = await resolved.file.readAsBytes();
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
      final resolved = await _resolveExistingSource(sourceUri);
      if (resolved != null && await resolved.file.exists()) {
        await resolved.file.delete();
      }
    } catch (_) {
      // 删除失败不阻断主流程
    }
  }

  @override
  Future<CachedRenderEntry?> findCached(String key) async {
    if (!_validKeyRe.hasMatch(key)) return null;
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
        try {
          await entity.setLastModified(DateTime.now());
        } catch (_) {
          // Ignore mtime touch failure.
        }
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
    if (!_validKeyRe.hasMatch(key) || bytes.isEmpty) {
      return;
    }
    await _ensureDirs();
    final safeW = width < 1 ? 1 : width;
    final safeH = height < 1 ? 1 : height;
    final safeExt = ext.toLowerCase() == 'png' ? 'png' : 'jpg';
    final target = File(
      p.join(_cacheRenderDir!.path, 'cache_${key}_${safeW}x$safeH.$safeExt'),
    );
    final tmp = File(
      p.join(_cacheRenderDir!.path, '.tmp_${key}_${++_tmpSeq}.$safeExt'),
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      await tmp.rename(target.path);
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  @override
  Future<void> pruneCached(int keep) async {
    try {
      await _ensureDirs();
      final entries = <({File file, DateTime modified})>[];
      await for (final entity in _cacheRenderDir!.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!_cacheNameRe.hasMatch(name)) continue;
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

  Future<void> _pruneExportDirs() async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 30));
      final dirs = <({Directory dir, DateTime modified})>[];
      await for (final entity in _exportDir!.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        } else if (entity is Directory) {
          final stat = await entity.stat();
          dirs.add((dir: entity, modified: stat.modified));
        }
      }
      dirs.sort((a, b) => b.modified.compareTo(a.modified));
      for (var i = 0; i < dirs.length; i++) {
        final item = dirs[i];
        if (i >= 10 || item.modified.isBefore(cutoff)) {
          try {
            await item.dir.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {
      // Ignore cleanup failures.
    }
  }

  @override
  Future<String?> writeExportTempFile(Uint8List bytes, String fileName) async {
    await _ensureDirs();
    final cleanName = p.basename(fileName).isNotEmpty ? p.basename(fileName) : 'export.bin';
    final shareDir = Directory(
      p.join(
        _exportDir!.path,
        'share_${DateTime.now().millisecondsSinceEpoch}_${++_tmpSeq}',
      ),
    );
    await shareDir.create(recursive: true);
    final file = File(p.join(shareDir.path, cleanName));
    await file.writeAsBytes(bytes, flush: true);
    // Clean up older staging directories asynchronously after writing the current one.
    Future<void>.microtask(_pruneExportDirs);
    return file.path;
  }
}

AppStorage createPlatformStorage() => IoAppStorage();
