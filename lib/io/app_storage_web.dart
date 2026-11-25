import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import '../state/page_models.dart';
import 'app_storage.dart';

@JS('indexedDB')
external _IDBFactory? get _indexedDB;

@JS()
extension type _IDBFactory(JSObject _) implements JSObject {
  external _IDBOpenDBRequest open(String name, [int version]);
}

@JS()
extension type _DOMStringList(JSObject _) implements JSObject {
  external bool contains(String name);
}

@JS()
extension type _DOMException(JSObject _) implements JSObject {
  external String? get message;
}

@JS()
extension type _IDBRequest(JSObject _) implements JSObject {
  external JSAny? get result;
  external _DOMException? get error;
  external set onsuccess(JSFunction? fn);
  external set onerror(JSFunction? fn);
}

@JS()
extension type _IDBOpenDBRequest(JSObject _) implements _IDBRequest {
  external set onupgradeneeded(JSFunction? fn);
  external set onblocked(JSFunction? fn);
}

@JS()
extension type _IDBDatabase(JSObject _) implements JSObject {
  external _DOMStringList get objectStoreNames;
  external _IDBObjectStore createObjectStore(String name);
  external _IDBTransaction transaction(JSAny storeNames, [String mode]);
  external void close();
  external set onclose(JSFunction? fn);
  external set onversionchange(JSFunction? fn);
}

@JS()
extension type _IDBTransaction(JSObject _) implements JSObject {
  external _IDBObjectStore objectStore(String name);
  external set oncomplete(JSFunction? fn);
  external set onerror(JSFunction? fn);
  external set onabort(JSFunction? fn);
}

@JS()
extension type _IDBObjectStore(JSObject _) implements JSObject {
  @JS('get')
  external _IDBRequest getByKey(JSAny key);
  external _IDBRequest put(JSAny? value, [JSAny? key]);
  external _IDBRequest delete(JSAny key);
  external _IDBRequest getAllKeys();
}

Future<JSAny?> _awaitRequest(_IDBRequest req) {
  final completer = Completer<JSAny?>();
  req.onsuccess = ((JSAny? _) {
    req.onsuccess = null;
    req.onerror = null;
    if (!completer.isCompleted) {
      completer.complete(req.result);
    }
  }).toJS;
  req.onerror = ((JSAny? _) {
    req.onsuccess = null;
    req.onerror = null;
    if (!completer.isCompleted) {
      completer.completeError(
        StateError(req.error?.message ?? 'IndexedDB request failed'),
      );
    }
  }).toJS;
  return completer.future;
}

Future<void> _awaitTx(_IDBTransaction tx) {
  final completer = Completer<void>();
  tx.oncomplete = ((JSAny? _) {
    tx.oncomplete = null;
    tx.onerror = null;
    tx.onabort = null;
    if (!completer.isCompleted) {
      completer.complete();
    }
  }).toJS;
  tx.onerror = ((JSAny? _) {
    tx.oncomplete = null;
    tx.onerror = null;
    tx.onabort = null;
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB transaction failed'));
    }
  }).toJS;
  tx.onabort = ((JSAny? _) {
    tx.oncomplete = null;
    tx.onerror = null;
    tx.onabort = null;
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB transaction aborted'));
    }
  }).toJS;
  return completer.future;
}

Uint8List? _asUint8List(JSAny? raw) {
  if (raw == null) return null;
  if (raw.isA<JSUint8Array>()) {
    return (raw as JSUint8Array).toDart;
  }
  if (raw.isA<JSArrayBuffer>()) {
    return (raw as JSArrayBuffer).toDart.asUint8List();
  }
  return null;
}

class IndexedDbAppStorage implements AppStorage {
  static const String _dbName = 'saomiao_flutter_db';
  static const int _dbVersion = 1;
  static const String _metaStore = 'meta';
  static const String _sourcesStore = 'sources';
  static const String _rendersStore = 'renders';
  static const String _pagesKey = 'pages';
  static const int _cacheHeaderBytes = 18;
  static final RegExp _validKeyRe = RegExp(r'^[a-z0-9]{1,64}$', caseSensitive: false);

  final MemoryAppStorage _fallback = MemoryAppStorage();
  final LinkedHashMap<String, double> _cacheTouchOrder = LinkedHashMap<String, double>();

  _IDBDatabase? _db;
  Future<_IDBDatabase?>? _openFuture;
  bool _dbUnavailable = false;
  int _clock = 0;
  int _dbEpoch = 0;

  @override
  bool get isPersistent => !_dbUnavailable && _indexedDB != null;

  Future<_IDBDatabase?> _getDb() {
    if (_db != null) return Future<_IDBDatabase?>.value(_db);
    if (_dbUnavailable || _indexedDB == null) {
      _dbUnavailable = true;
      return Future<_IDBDatabase?>.value(null);
    }
    return _openFuture ??= _openDb();
  }

  Future<_IDBDatabase?> _openDb() async {
    try {
      final factory = _indexedDB;
      if (factory == null) {
        _dbUnavailable = true;
        return null;
      }
      final req = factory.open(_dbName, _dbVersion);
      final completer = Completer<_IDBDatabase?>();
      req.onupgradeneeded = ((JSAny? _) {
        final db = req.result as _IDBDatabase?;
        if (db == null) return;
        final names = db.objectStoreNames;
        if (!names.contains(_metaStore)) db.createObjectStore(_metaStore);
        if (!names.contains(_sourcesStore)) db.createObjectStore(_sourcesStore);
        if (!names.contains(_rendersStore)) db.createObjectStore(_rendersStore);
      }).toJS;
      req.onsuccess = ((JSAny? _) {
        req.onupgradeneeded = null;
        req.onsuccess = null;
        req.onerror = null;
        req.onblocked = null;
        final db = req.result as _IDBDatabase?;
        _openFuture = null;
        if (db == null) {
          _dbUnavailable = true;
        } else {
          final epoch = ++_dbEpoch;
          db.onclose = ((JSAny? _) {
            if (epoch == _dbEpoch) {
              _db = null;
              _openFuture = null;
            }
          }).toJS;
          db.onversionchange = ((JSAny? _) {
            if (epoch == _dbEpoch) {
              _db = null;
              _openFuture = null;
            }
            try {
              db.close();
            } catch (_) {}
          }).toJS;
          _db = db;
        }
        if (!completer.isCompleted) completer.complete(db);
      }).toJS;
      req.onerror = ((JSAny? _) {
        req.onupgradeneeded = null;
        req.onsuccess = null;
        req.onerror = null;
        req.onblocked = null;
        _openFuture = null;
        _dbUnavailable = true;
        if (!completer.isCompleted) completer.complete(null);
      }).toJS;
      req.onblocked = ((JSAny? _) {
        req.onupgradeneeded = null;
        req.onsuccess = null;
        req.onerror = null;
        req.onblocked = null;
        _openFuture = null;
        _dbUnavailable = true;
        if (!completer.isCompleted) completer.complete(null);
      }).toJS;
      return await completer.future;
    } catch (_) {
      _openFuture = null;
      _dbUnavailable = true;
      return null;
    }
  }

  @override
  Future<List<PageItem>> loadPages() async {
    final db = await _getDb();
    if (db == null) return _fallback.loadPages();
    try {
      final tx = db.transaction(_metaStore.toJS, 'readonly');
      final raw = await _awaitRequest(tx.objectStore(_metaStore).getByKey(_pagesKey.toJS));
      if (raw == null || !raw.isA<JSString>()) return const <PageItem>[];
      final decoded = jsonDecode((raw as JSString).toDart);
      if (decoded is! List) return const <PageItem>[];

      final candidates = <PageItem>[];
      for (final row in decoded) {
        final item = PageItem.tryFromJson(row);
        if (item != null) candidates.add(item);
      }
      if (candidates.isEmpty) return const <PageItem>[];

      final srcTx = db.transaction(_sourcesStore.toJS, 'readonly');
      final keysRaw = await _awaitRequest(srcTx.objectStore(_sourcesStore).getAllKeys());
      final existingKeys = <String>{};
      if (keysRaw != null && keysRaw.isA<JSArray>()) {
        final arr = (keysRaw as JSArray).toDart;
        for (final k in arr) {
          if (k != null && k.isA<JSString>()) {
            existingKeys.add((k as JSString).toDart);
          }
        }
      }

      return candidates
          .where((item) => existingKeys.contains(item.sourceUri))
          .toList(growable: false);
    } catch (_) {
      return const <PageItem>[];
    }
  }

  @override
  Future<void> savePages(List<PageItem> pages) async {
    final db = await _getDb();
    if (db == null) return _fallback.savePages(pages);
    final jsonText = jsonEncode(pages.map((p) => p.toJson()).toList(growable: false));
    final tx = db.transaction(_metaStore.toJS, 'readwrite');
    tx.objectStore(_metaStore).put(jsonText.toJS, _pagesKey.toJS);
    await _awaitTx(tx);
  }

  @override
  Future<String> saveSourceBytes(
    Uint8List bytes,
    String pageId,
    String? fileName,
  ) async {
    final db = await _getDb();
    if (db == null) return _fallback.saveSourceBytes(bytes, pageId, fileName);
    final uri = 'idb://orig/$pageId';
    final tx = db.transaction(_sourcesStore.toJS, 'readwrite');
    tx.objectStore(_sourcesStore).put(bytes.toJS, uri.toJS);
    await _awaitTx(tx);
    return uri;
  }

  @override
  Future<Uint8List> readSourceBytes(String sourceUri) async {
    final db = await _getDb();
    if (db == null) return _fallback.readSourceBytes(sourceUri);
    try {
      final tx = db.transaction(_sourcesStore.toJS, 'readonly');
      final raw = await _awaitRequest(tx.objectStore(_sourcesStore).getByKey(sourceUri.toJS));
      final bytes = _asUint8List(raw);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('图片无法解析：读取原图失败');
      }
      return bytes;
    } catch (_) {
      throw StateError('图片无法解析：读取原图失败');
    }
  }

  @override
  Future<void> deleteSource(String sourceUri) async {
    final db = await _getDb();
    if (db == null) return _fallback.deleteSource(sourceUri);
    try {
      final tx = db.transaction(_sourcesStore.toJS, 'readwrite');
      tx.objectStore(_sourcesStore).delete(sourceUri.toJS);
      await _awaitTx(tx);
    } catch (_) {
      // 删除失败不阻断主流程
    }
  }

  Uint8List _packCachedEntry(
    Uint8List payload,
    String ext,
    int width,
    int height,
    double touched,
  ) {
    final packed = Uint8List(_cacheHeaderBytes + payload.length);
    final header = ByteData.sublistView(packed, 0, _cacheHeaderBytes);
    header.setUint8(0, 1);
    header.setUint8(1, ext.toLowerCase() == 'png' ? 1 : 0);
    header.setUint32(2, width < 1 ? 1 : width);
    header.setUint32(6, height < 1 ? 1 : height);
    header.setFloat64(10, touched);
    packed.setRange(_cacheHeaderBytes, packed.length, payload);
    return packed;
  }

  ({CachedRenderEntry entry, double touched})? _unpackCachedEntry(Uint8List raw) {
    if (raw.length <= _cacheHeaderBytes) return null;
    final header = ByteData.sublistView(raw, 0, _cacheHeaderBytes);
    if (header.getUint8(0) != 1) return null;
    final fmt = header.getUint8(1) == 1 ? 'png' : 'jpeg';
    final width = header.getUint32(2);
    final height = header.getUint32(6);
    final touched = header.getFloat64(10);
    final payload = Uint8List.sublistView(raw, _cacheHeaderBytes);
    if (payload.isEmpty) return null;
    return (
      entry: CachedRenderEntry(
        bytes: payload,
        width: width,
        height: height,
        format: fmt,
      ),
      touched: touched,
    );
  }

  double _nextTouch() =>
      DateTime.now().millisecondsSinceEpoch.toDouble() + (++_clock) / 1000000.0;

  @override
  Future<CachedRenderEntry?> findCached(String key) async {
    if (!_validKeyRe.hasMatch(key)) return null;
    final db = await _getDb();
    if (db == null) return _fallback.findCached(key);
    try {
      final tx = db.transaction(_rendersStore.toJS, 'readonly');
      final raw = await _awaitRequest(tx.objectStore(_rendersStore).getByKey(key.toJS));
      final bytes = _asUint8List(raw);
      if (bytes == null) return null;
      final unpacked = _unpackCachedEntry(bytes);
      if (unpacked == null) return null;
      _cacheTouchOrder.remove(key);
      _cacheTouchOrder[key] = _nextTouch();
      return unpacked.entry;
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
    if (!_validKeyRe.hasMatch(key) || bytes.isEmpty) return;
    final db = await _getDb();
    if (db == null) return _fallback.writeCached(key, bytes, ext, width, height);
    final touched = _nextTouch();
    final packed = _packCachedEntry(bytes, ext, width, height, touched);
    final tx = db.transaction(_rendersStore.toJS, 'readwrite');
    tx.objectStore(_rendersStore).put(packed.toJS, key.toJS);
    await _awaitTx(tx);
    _cacheTouchOrder.remove(key);
    _cacheTouchOrder[key] = touched;
  }

  @override
  Future<void> pruneCached(int keep) async {
    final db = await _getDb();
    if (db == null) return _fallback.pruneCached(keep);
    try {
      final safeKeep = keep < 0 ? 0 : keep;
      final tx = db.transaction(_rendersStore.toJS, 'readonly');
      final keysRaw = await _awaitRequest(tx.objectStore(_rendersStore).getAllKeys());
      if (keysRaw == null || !keysRaw.isA<JSArray>()) return;
      final allKeys = <String>[];
      for (final k in (keysRaw as JSArray).toDart) {
        if (k != null && k.isA<JSString>()) {
          allKeys.add((k as JSString).toDart);
        }
      }
      if (allKeys.length <= safeKeep) return;

      final missingKeys = allKeys
          .where((k) => !_cacheTouchOrder.containsKey(k))
          .toList(growable: false);
      if (missingKeys.isNotEmpty) {
        final readTx = db.transaction(_rendersStore.toJS, 'readonly');
        final readStore = readTx.objectStore(_rendersStore);
        final rawValues = await Future.wait(
          missingKeys.map(
            (k) => _awaitRequest(readStore.getByKey(k.toJS))
                .then<JSAny?>((v) => v, onError: (_) => null),
          ),
        );
        for (var i = 0; i < missingKeys.length; i++) {
          final bytes = _asUint8List(rawValues[i]);
          final t = bytes != null ? (_unpackCachedEntry(bytes)?.touched ?? 0.0) : 0.0;
          _cacheTouchOrder[missingKeys[i]] = t;
        }
      }

      final scored = <({String key, double touched})>[
        for (final k in allKeys) (key: k, touched: _cacheTouchOrder[k] ?? 0.0),
      ];
      scored.sort((a, b) => b.touched.compareTo(a.touched));
      final toDelete = scored.skip(safeKeep).map((e) => e.key).toList(growable: false);
      if (toDelete.isEmpty) return;
      final delTx = db.transaction(_rendersStore.toJS, 'readwrite');
      final store = delTx.objectStore(_rendersStore);
      for (final k in toDelete) {
        store.delete(k.toJS);
        _cacheTouchOrder.remove(k);
      }
      await _awaitTx(delTx);
    } catch (_) {
      // Ignore prune failures.
    }
  }

  @override
  Future<String?> writeExportTempFile(Uint8List bytes, String fileName) async => null;
}

AppStorage createPlatformStorage() => IndexedDbAppStorage();
