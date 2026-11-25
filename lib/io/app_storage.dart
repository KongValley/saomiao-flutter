import 'dart:typed_data';

import '../state/page_models.dart';
import 'app_storage_io.dart';

class CachedRenderEntry {
  const CachedRenderEntry({
    required this.bytes,
    required this.width,
    required this.height,
    required this.format,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String format; // 'png' | 'jpeg'
}

abstract interface class AppStorage {
  bool get isPersistent;

  Future<List<PageItem>> loadPages();
  Future<void> savePages(List<PageItem> pages);

  Future<DocumentLibrary?> loadLibrary();
  Future<void> saveLibrary(DocumentLibrary library);

  Future<AppPreferences> loadPreferences();
  Future<void> savePreferences(AppPreferences prefs);

  Future<List<CustomPreset>> loadCustomPresets();
  Future<void> saveCustomPresets(List<CustomPreset> presets);

  Future<List<SavedSignature>> loadSignatures();
  Future<void> saveSignatures(List<SavedSignature> signatures);
  Future<String> saveSignatureBytes(Uint8List pngBytes, String sigId);
  Future<Uint8List?> readSignatureBytes(String uri);
  Future<void> deleteSignatureBytes(String uri);

  Future<String> saveSourceBytes(Uint8List bytes, String pageId, String? fileName);
  Future<Uint8List> readSourceBytes(String sourceUri);
  Future<void> deleteSource(String sourceUri);

  Future<CachedRenderEntry?> findCached(String key);
  Future<void> writeCached(
    String key,
    Uint8List bytes,
    String ext,
    int width,
    int height,
  );
  Future<void> pruneCached(int keep);

  /// 在原生端写临时导出文件供系统分享
  Future<String?> writeExportTempFile(Uint8List bytes, String fileName);
}

AppStorage createAppStorage() => createPlatformStorage();

/// 内存存储（用于单元测试）
class MemoryAppStorage implements AppStorage {
  final Map<String, Uint8List> _sources = <String, Uint8List>{};
  final Map<String, ({CachedRenderEntry entry, int touched})> _cache =
      <String, ({CachedRenderEntry entry, int touched})>{};
  List<PageItem> _pages = const <PageItem>[];
  DocumentLibrary? _library;
  AppPreferences _prefs = const AppPreferences();
  List<CustomPreset> _presets = const <CustomPreset>[];
  List<SavedSignature> _signatures = const <SavedSignature>[];
  final Map<String, Uint8List> _signatureBytes = <String, Uint8List>{};
  int _clock = 0;

  @override
  bool get isPersistent => false;

  @override
  Future<List<PageItem>> loadPages() async => _pages;

  @override
  Future<void> savePages(List<PageItem> pages) async {
    _pages = List<PageItem>.unmodifiable(pages);
  }

  @override
  Future<DocumentLibrary?> loadLibrary() async {
    if (_library != null) return _library;
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
  }

  @override
  Future<void> saveLibrary(DocumentLibrary library) async {
    _library = library;
    await savePages(library.activeDocument.pages);
  }

  @override
  Future<AppPreferences> loadPreferences() async => _prefs;

  @override
  Future<void> savePreferences(AppPreferences prefs) async {
    _prefs = prefs;
  }

  @override
  Future<List<CustomPreset>> loadCustomPresets() async => _presets;

  @override
  Future<void> saveCustomPresets(List<CustomPreset> presets) async {
    _presets = List<CustomPreset>.unmodifiable(presets);
  }

  @override
  Future<List<SavedSignature>> loadSignatures() async => _signatures;

  @override
  Future<void> saveSignatures(List<SavedSignature> signatures) async {
    _signatures = List<SavedSignature>.unmodifiable(signatures);
  }

  @override
  Future<String> saveSignatureBytes(Uint8List pngBytes, String sigId) async {
    final uri = 'mem-sig://$sigId';
    _signatureBytes[uri] = pngBytes;
    return uri;
  }

  @override
  Future<Uint8List?> readSignatureBytes(String uri) async => _signatureBytes[uri];

  @override
  Future<void> deleteSignatureBytes(String uri) async {
    _signatureBytes.remove(uri);
  }

  @override
  Future<String> saveSourceBytes(
    Uint8List bytes,
    String pageId,
    String? fileName,
  ) async {
    final key = 'mem://$pageId';
    _sources[key] = bytes;
    return key;
  }

  @override
  Future<Uint8List> readSourceBytes(String sourceUri) async {
    final data = _sources[sourceUri];
    if (data == null || data.isEmpty) {
      throw StateError('图片无法解析：读取原图失败');
    }
    return data;
  }

  @override
  Future<void> deleteSource(String sourceUri) async {
    _sources.remove(sourceUri);
  }

  @override
  Future<CachedRenderEntry?> findCached(String key) async {
    final hit = _cache[key];
    if (hit == null) return null;
    _cache[key] = (entry: hit.entry, touched: ++_clock);
    return hit.entry;
  }

  @override
  Future<void> writeCached(
    String key,
    Uint8List bytes,
    String ext,
    int width,
    int height,
  ) async {
    if (!RegExp(r'^[a-z0-9]{1,64}$', caseSensitive: false).hasMatch(key)) {
      return;
    }
    if (bytes.isEmpty) return;
    _cache[key] = (
      entry: CachedRenderEntry(
        bytes: bytes,
        width: width,
        height: height,
        format: ext == 'png' ? 'png' : 'jpeg',
      ),
      touched: ++_clock,
    );
  }

  @override
  Future<void> pruneCached(int keep) async {
    if (_cache.length <= keep) return;
    final sorted = _cache.entries.toList()
      ..sort((a, b) => b.value.touched.compareTo(a.value.touched));
    for (final e in sorted.skip(keep < 0 ? 0 : keep)) {
      _cache.remove(e.key);
    }
  }

  @override
  Future<String?> writeExportTempFile(Uint8List bytes, String fileName) async => null;
}
