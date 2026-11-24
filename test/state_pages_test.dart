import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/engine/options.dart';
import 'package:saomiao_flutter/state/page_models.dart';

const List<CornerPoint> _corners = [
  CornerPoint(0.1, 0.1),
  CornerPoint(0.9, 0.12),
  CornerPoint(0.88, 0.9),
  CornerPoint(0.12, 0.88),
];

PageItem _page(String id, [Object? options]) => PageItem(
      id: id,
      name: '$id.jpg',
      createdAt: 1,
      sourceUri: 'file:///documents/$id.jpg',
      sourceW: 1200,
      sourceH: 1600,
      options: normalizeOptions(options),
    );

void main() {
  test('toStylePatch：不同步 corners / rotate，其余参数原样带出', () {
    final options = ScanOptions.defaults.copyWith(
      mode: ScanMode.gray,
      contrast: 70,
      corners: _corners,
      rotate: 90,
    );
    final patch = options.toStylePatch();
    expect(patch.containsKey('corners'), isFalse);
    expect(patch.containsKey('rotate'), isFalse);
    expect(patch['mode'], 'gray');
    expect(patch['contrast'], 70);
  });

  test('updateAllOptions 与 restoreOptions：批量改参保留四角与旋转并支持撤销', () {
    final gray = ScanOptions.defaults.copyWith(mode: ScanMode.gray, contrast: 70);
    final before = PagesState(
      pages: [
        _page('pg_a', gray.copyWith(corners: _corners, rotate: 90)),
        _page('pg_b', ScanOptions.defaults.copyWith(corners: _corners)),
        _page('pg_c', ScanOptions.defaults.copyWith(rotate: 180)),
      ],
    );
    final snapshot = {for (final p in before.pages) p.id: p.options};

    final applied = before.updateAllOptions(gray.toStylePatch());
    for (final p in applied.pages) {
      expect(p.options.mode, ScanMode.gray);
      expect(p.options.contrast, 70);
    }
    expect(applied.pages[0].options.rotate, 90);
    expect(applied.pages[1].options.corners, _corners);
    expect(applied.pages[2].options.rotate, 180);
    expect(applied.pages[2].options.corners, isNull);

    final restored = applied.restoreOptions(snapshot);
    expect(restored.pages[0].options.rotate, 90);
    expect(restored.pages[1].options.mode, ScanMode.bw);
    expect(restored.pages[1].options.corners, _corners);
  });

  test('movePage / removePage / rotatePage / dragTargetIndex', () {
    final state = PagesState(
      pages: [_page('a'), _page('b'), _page('c')],
      currentIndex: 1,
    );
    final moved = state.movePage(1, 0);
    expect(moved.pages.map((p) => p.id).toList(), ['b', 'a', 'c']);
    expect(moved.currentIndex, 0);

    final rotated = moved.rotatePage('b');
    expect(rotated.pages[0].options.rotate, 90);

    final removed = rotated.removePage('b');
    expect(removed.pages.map((p) => p.id).toList(), ['a', 'c']);
    expect(removed.formatPageCounter(), '第 1 / 共 2 页');

    expect(dragTargetIndex(0, 66, 66, 3), 1);
    expect(dragTargetIndex(0, 132, 66, 3), 2);
    expect(dragTargetIndex(2, -200, 66, 3), 0);
  });
}
