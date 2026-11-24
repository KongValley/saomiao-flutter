import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

const double _mmToPt = 72.0 / 25.4;
const ({double width, double height}) _a4 = (width: 595.28, height: 841.89);
const ({double width, double height}) _letter = (width: 612.0, height: 792.0);
const String _defaultTitle = '扫描件';

enum PdfPageSize {
  a4('a4'),
  letter('letter'),
  auto('auto');

  const PdfPageSize(this.value);
  final String value;

  static PdfPageSize tryParse(Object? raw) {
    if (raw is PdfPageSize) return raw;
    if (raw is String) {
      for (final v in values) {
        if (v.value == raw) return v;
      }
    }
    return PdfPageSize.a4;
  }
}

enum PdfOrientation {
  auto('auto'),
  portrait('portrait'),
  landscape('landscape');

  const PdfOrientation(this.value);
  final String value;

  static PdfOrientation tryParse(Object? raw) {
    if (raw is PdfOrientation) return raw;
    if (raw is String) {
      for (final v in values) {
        if (v.value == raw) return v;
      }
    }
    return PdfOrientation.auto;
  }
}

class PdfOptions {
  const PdfOptions({
    this.pageSize = PdfPageSize.a4,
    this.orientation = PdfOrientation.auto,
    this.marginMm = 10,
    this.title,
  });

  final PdfPageSize pageSize;
  final PdfOrientation orientation;
  final double marginMm;
  final String? title;

  PdfOptions copyWith({
    PdfPageSize? pageSize,
    PdfOrientation? orientation,
    double? marginMm,
    String? title,
  }) {
    return PdfOptions(
      pageSize: pageSize ?? this.pageSize,
      orientation: orientation ?? this.orientation,
      marginMm: marginMm ?? this.marginMm,
      title: title ?? this.title,
    );
  }
}

class PdfPageInput {
  const PdfPageInput({
    required this.jpegBytes,
    this.width,
    this.height,
    this.channels,
  });

  final Uint8List jpegBytes;
  final int? width;
  final int? height;
  final int? channels;
}

class _JpegInfo {
  const _JpegInfo({
    required this.width,
    required this.height,
    required this.components,
  });

  final int width;
  final int height;
  final int components;
}

class _PagePlan {
  const _PagePlan({
    required this.bytes,
    required this.imgW,
    required this.imgH,
    required this.components,
    required this.pageW,
    required this.pageH,
    required this.drawW,
    required this.drawH,
    required this.x,
    required this.y,
  });

  final Uint8List bytes;
  final int imgW;
  final int imgH;
  final int components;
  final double pageW;
  final double pageH;
  final double drawW;
  final double drawH;
  final double x;
  final double y;
}

String _fmt(double v) {
  if (!v.isFinite) return '0';
  final r = (v * 100.0).round() / 100.0;
  if (r == r.roundToDouble()) return r.round().toString();
  return r.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

_JpegInfo? _scanJpeg(Uint8List buf) {
  if (buf.length < 4) return null;
  if (buf[0] != 0xff || buf[1] != 0xd8) return null;
  var i = 2;
  while (i + 3 < buf.length) {
    if (buf[i] != 0xff) {
      i++;
      continue;
    }
    final marker = buf[i + 1];
    if (marker == 0xff) {
      i++;
      continue;
    }
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      i += 2;
      continue;
    }
    if (marker == 0xd9) break;
    final len = (buf[i + 2] << 8) | buf[i + 3];
    if (len < 2) break;
    final isSof = (marker >= 0xc0 && marker <= 0xc3) ||
        (marker >= 0xc5 && marker <= 0xc7) ||
        (marker >= 0xc9 && marker <= 0xcb) ||
        (marker >= 0xcd && marker <= 0xcf);
    if (isSof) {
      if (i + 9 >= buf.length) break;
      final height = (buf[i + 5] << 8) | buf[i + 6];
      final width = (buf[i + 7] << 8) | buf[i + 8];
      final components = buf[i + 9];
      return _JpegInfo(
        width: width,
        height: height,
        components: components == 0 ? 3 : components,
      );
    }
    if (marker == 0xda) break;
    i += 2 + len;
  }
  return null;
}

({double width, double height}) _resolvePageSize(
  PdfPageSize pageSize,
  PdfOrientation orientation,
  int imageWidth,
  int imageHeight,
) {
  final ratio = imageWidth > 0 && imageHeight > 0 ? imageWidth / imageHeight : 1.0;
  final landscapeByImage = ratio > 1.0;

  if (pageSize == PdfPageSize.auto) {
    final longEdge = _a4.height;
    double width;
    double height;
    if (ratio >= 1.0) {
      width = longEdge;
      height = longEdge / ratio;
    } else {
      height = longEdge;
      width = longEdge * ratio;
    }
    if (orientation == PdfOrientation.portrait && width > height) {
      final tmp = width;
      width = height;
      height = tmp;
    } else if (orientation == PdfOrientation.landscape && height > width) {
      final tmp = width;
      width = height;
      height = tmp;
    }
    return (width: width, height: height);
  }

  final base = pageSize == PdfPageSize.letter ? _letter : _a4;
  final wantLandscape = orientation == PdfOrientation.landscape ||
      (orientation == PdfOrientation.auto && landscapeByImage);
  return wantLandscape
      ? (width: base.height, height: base.width)
      : (width: base.width, height: base.height);
}

String _colorSpaceName(int components) {
  if (components == 1) return 'DeviceGray';
  if (components == 4) return 'DeviceCMYK';
  return 'DeviceRGB';
}

String _pdfDate(DateTime date) {
  String pad(int n) => n.toString().padLeft(2, '0');
  final offMin = date.timeZoneOffset.inMinutes;
  final sign = offMin >= 0 ? '+' : '-';
  final abs = offMin.abs();
  return 'D:'
      '${date.year}'
      '${pad(date.month)}'
      '${pad(date.day)}'
      '${pad(date.hour)}'
      '${pad(date.minute)}'
      '${pad(date.second)}'
      '$sign'
      '${pad(abs ~/ 60)}'
      "'"
      '${pad(abs % 60)}'
      "'";
}

String _utf16HexString(String text) {
  final buf = StringBuffer('<FEFF');
  for (final code in text.codeUnits) {
    buf.write(code.toRadixString(16).toUpperCase().padLeft(4, '0'));
  }
  buf.write('>');
  return buf.toString();
}

String _pdfTextString(String text) {
  return '(${text.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)')})';
}

Uint8List _asciiBytes(String str) {
  return Uint8List.fromList(latin1.encode(str));
}

/// 生成多页 PDF（零依赖自写 PDF 1.4，JPEG 直接走 /DCTDecode 内嵌）
Uint8List buildPdf(List<PdfPageInput> pages, [PdfOptions opts = const PdfOptions()]) {
  if (pages.isEmpty) {
    throw StateError('PDF 至少需要 1 页');
  }
  final marginMm = opts.marginMm.isFinite ? opts.marginMm.clamp(0.0, 40.0) : 0.0;
  final title = (opts.title != null && opts.title!.isNotEmpty) ? opts.title! : _defaultTitle;

  final plans = <_PagePlan>[];
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    final bytes = page.jpegBytes;
    if (bytes.isEmpty) {
      throw StateError('第 ${i + 1} 页图片为空');
    }
    if (bytes.length < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) {
      throw StateError('第 ${i + 1} 页图片不是 JPEG，无法嵌入 PDF');
    }
    final info = _scanJpeg(bytes);
    final imgW = (info != null && info.width > 0) ? info.width : (page.width ?? 0);
    final imgH = (info != null && info.height > 0) ? info.height : (page.height ?? 0);
    if (imgW <= 0 || imgH <= 0) {
      throw StateError('第 ${i + 1} 页图片缺少有效尺寸');
    }
    final components = info?.components ?? (page.channels == 1 ? 1 : 3);

    final size = _resolvePageSize(opts.pageSize, opts.orientation, imgW, imgH);
    final pageW = size.width;
    final pageH = size.height;
    final marginPt = math.min(marginMm * _mmToPt, math.min(pageW, pageH) / 2.0 - 1.0);
    final availW = math.max(1.0, pageW - marginPt * 2.0);
    final availH = math.max(1.0, pageH - marginPt * 2.0);
    final scale = math.min(availW / imgW, availH / imgH);
    final drawW = imgW * scale;
    final drawH = imgH * scale;
    plans.add(
      _PagePlan(
        bytes: bytes,
        imgW: imgW,
        imgH: imgH,
        components: components,
        pageW: pageW,
        pageH: pageH,
        drawW: drawW,
        drawH: drawH,
        x: (pageW - drawW) / 2.0,
        y: (pageH - drawH) / 2.0,
      ),
    );
  }

  int pageObjId(int i) => 4 + i * 3;
  int contentObjId(int i) => 5 + i * 3;
  int imageObjId(int i) => 6 + i * 3;
  final objCount = 3 + pages.length * 3;

  final builder = BytesBuilder(copy: false);
  var total = 0;
  final offsets = List<int>.filled(objCount + 1, 0);

  void writeBytes(Uint8List bytes) {
    builder.add(bytes);
    total += bytes.length;
  }

  void writeStr(String str) => writeBytes(_asciiBytes(str));

  void beginObj(int id) {
    offsets[id] = total;
    writeStr('$id 0 obj\n');
  }

  void endObj() => writeStr('endobj\n');

  writeStr('%PDF-1.4\n');
  writeBytes(Uint8List.fromList(<int>[0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]));

  // 1: Catalog
  beginObj(1);
  writeStr('<< /Type /Catalog /Pages 2 0 R >>\n');
  endObj();

  // 2: Pages
  beginObj(2);
  final kids = List<String>.generate(pages.length, (i) => '${pageObjId(i)} 0 R').join(' ');
  writeStr('<< /Type /Pages /Count ${pages.length} /Kids [$kids] >>\n');
  endObj();

  // 3: Info
  beginObj(3);
  writeStr(
    '<< /Title ${_utf16HexString(title)}'
    ' /Producer ${_pdfTextString('saomiao-flutter 1.0.0')}'
    ' /Creator ${_pdfTextString('saomiao-flutter')}'
    ' /CreationDate ${_pdfTextString(_pdfDate(DateTime.now()))} >>\n',
  );
  endObj();

  // 每页对象
  for (var i = 0; i < pages.length; i++) {
    final p = plans[i];
    final pId = pageObjId(i);
    final cId = contentObjId(i);
    final iId = imageObjId(i);

    beginObj(pId);
    writeStr(
      '<< /Type /Page /Parent 2 0 R'
      ' /MediaBox [0 0 ${_fmt(p.pageW)} ${_fmt(p.pageH)}]'
      ' /Resources << /XObject << /Im0 $iId 0 R >> >>'
      ' /Contents $cId 0 R >>\n',
    );
    endObj();

    final content = 'q\n'
        '${_fmt(p.drawW)} 0 0 ${_fmt(p.drawH)} ${_fmt(p.x)} ${_fmt(p.y)} cm\n'
        '/Im0 Do\n'
        'Q\n';
    beginObj(cId);
    writeStr('<< /Length ${content.length} >>\nstream\n${content}endstream\n');
    endObj();

    beginObj(iId);
    writeStr(
      '<< /Type /XObject /Subtype /Image'
      ' /Width ${p.imgW} /Height ${p.imgH}'
      ' /ColorSpace /${_colorSpaceName(p.components)}'
      ' /BitsPerComponent 8 /Filter /DCTDecode'
      ' /Length ${p.bytes.length} >>\nstream\n',
    );
    writeBytes(p.bytes);
    writeStr('\nendstream\n');
    endObj();
  }

  final xrefOffset = total;
  final xref = StringBuffer('xref\n0 ${objCount + 1}\n');
  xref.write('0000000000 65535 f\r\n');
  for (var id = 1; id <= objCount; id++) {
    xref.write('${offsets[id].toString().padLeft(10, '0')} 00000 n\r\n');
  }
  writeStr(xref.toString());
  writeStr(
    'trailer\n<< /Size ${objCount + 1} /Root 1 0 R /Info 3 0 R >>\n'
    'startxref\n$xrefOffset\n%%EOF\n',
  );

  return builder.takeBytes();
}

/// 文件名时间戳：yyyyMMdd-HHmm
String pdfTimestamp([DateTime? date]) {
  final d = date ?? DateTime.now();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${pad(d.month)}${pad(d.day)}-${pad(d.hour)}${pad(d.minute)}';
}
