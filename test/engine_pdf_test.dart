import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/engine/pdf.dart';

Uint8List _makeJpegStub(int width, int height, [int components = 3]) {
  final bytes = <int>[0xff, 0xd8];
  bytes.addAll([
    0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00,
    0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
  ]);
  final sofLen = 8 + 3 * components;
  bytes.addAll([0xff, 0xc0, (sofLen >> 8) & 0xff, sofLen & 0xff, 0x08]);
  bytes.addAll([(height >> 8) & 0xff, height & 0xff, (width >> 8) & 0xff, width & 0xff, components]);
  for (var i = 0; i < components; i++) {
    bytes.addAll([i + 1, 0x11, 0x00]);
  }
  final sosLen = 6 + 2 * components;
  bytes.addAll([0xff, 0xda, (sosLen >> 8) & 0xff, sosLen & 0xff, components]);
  for (var i = 0; i < components; i++) {
    bytes.addAll([i + 1, 0x00]);
  }
  bytes.addAll([0x00, 0x3f, 0x00, 0x12, 0x34, 0xff, 0x00, 0x56, 0x78, 0xff, 0xd9]);
  return Uint8List.fromList(bytes);
}

String _validateStructure(Uint8List bytes) {
  final text = latin1.decode(bytes);
  expect(text.startsWith('%PDF-1.4'), isTrue);
  expect(text.trimRight().endsWith('%%EOF'), isTrue);

  final sxMatch = RegExp(r'startxref\s+(\d+)\s+%%EOF').firstMatch(text);
  expect(sxMatch, isNotNull);
  final startxref = int.parse(sxMatch!.group(1)!);
  expect(text.substring(startxref, startxref + 4), 'xref');

  final head = RegExp(r'^xref\n0 (\d+)\n').firstMatch(text.substring(startxref));
  expect(head, isNotNull);
  final count = int.parse(head!.group(1)!);
  var pos = startxref + head.group(0)!.length;
  final entries = <String>[];
  for (var i = 0; i < count; i++) {
    final line = text.substring(pos, pos + 20);
    expect(RegExp(r'^\d{10} \d{5} [nf]\r\n$').hasMatch(line), isTrue);
    entries.add(line);
    pos += 20;
  }
  expect(entries[0][17], 'f');
  for (var id = 1; id < count; id++) {
    final offset = int.parse(entries[id].substring(0, 10));
    expect(text.startsWith('$id 0 obj', offset), isTrue);
  }
  return text;
}

void main() {
  test('buildPdf：基本结构、A4/Letter/Auto、横竖方向与 xref 偏移', () {
    final pdf = buildPdf([PdfPageInput(jpegBytes: _makeJpegStub(1200, 1600), width: 1200, height: 1600)]);
    final text = _validateStructure(pdf);
    expect(text.contains('/DCTDecode'), isTrue);
    expect(text.contains('/ColorSpace /DeviceRGB'), isTrue);
    expect(text.contains('/MediaBox [0 0 595.28 841.89]'), isTrue);

    final letter = _validateStructure(
      buildPdf(
        [PdfPageInput(jpegBytes: _makeJpegStub(1200, 1600))],
        const PdfOptions(pageSize: PdfPageSize.letter, orientation: PdfOrientation.portrait),
      ),
    );
    expect(letter.contains('/MediaBox [0 0 612 792]'), isTrue);

    final landscape = _validateStructure(
      buildPdf(
        [PdfPageInput(jpegBytes: _makeJpegStub(1600, 1200))],
        const PdfOptions(pageSize: PdfPageSize.a4, orientation: PdfOrientation.auto),
      ),
    );
    expect(landscape.contains('/MediaBox [0 0 841.89 595.28]'), isTrue);
  });

  test('buildPdf：多页、灰度 DeviceGray、UTF-16BE Title 与异常提示', () {
    final grayJpeg = _makeJpegStub(800, 1000, 1);
    final pdf = buildPdf([
      PdfPageInput(jpegBytes: grayJpeg),
      PdfPageInput(jpegBytes: _makeJpegStub(640, 480, 3)),
    ]);
    final text = _validateStructure(pdf);
    expect(text.contains('/Count 2 '), isTrue);
    expect(text.contains('/ColorSpace /DeviceGray'), isTrue);
    expect(text.contains('/Title <FEFF626B63CF4EF6>'), isTrue);
    expect(RegExp(r"/CreationDate \(D:\d{14}[+-]\d{2}'\d{2}'\)").hasMatch(text), isTrue);

    expect(() => buildPdf([]), throwsA(isA<StateError>().having((e) => e.message, 'msg', contains('至少需要 1 页'))));
    expect(
      () => buildPdf([PdfPageInput(jpegBytes: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]))]),
      throwsA(isA<StateError>().having((e) => e.message, 'msg', contains('不是 JPEG'))),
    );
  });
}
