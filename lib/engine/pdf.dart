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

class PdfOcrLine {
  const PdfOcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  static PdfOcrLine? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    final l = raw['left'];
    final t = raw['top'];
    final r = raw['right'];
    final b = raw['bottom'];
    if (text is! String || l is! num || t is! num || r is! num || b is! num) {
      return null;
    }
    return PdfOcrLine(
      text: text,
      left: l.toDouble().clamp(0.0, 1.0),
      top: t.toDouble().clamp(0.0, 1.0),
      right: r.toDouble().clamp(0.0, 1.0),
      bottom: b.toDouble().clamp(0.0, 1.0),
    );
  }
}

class PdfOptions {
  const PdfOptions({
    this.pageSize = PdfPageSize.a4,
    this.orientation = PdfOrientation.auto,
    this.marginMm = 10,
    this.title,
    this.jpegQuality = 0.92,
    this.showPageNumbers = false,
    this.watermarkText,
    this.watermarkOpacity = 0.20,
    this.embedOcrText = true,
  });

  final PdfPageSize pageSize;
  final PdfOrientation orientation;
  final double marginMm;
  final String? title;
  final double jpegQuality;
  final bool showPageNumbers;
  final String? watermarkText;
  final double watermarkOpacity;
  final bool embedOcrText;

  PdfOptions copyWith({
    PdfPageSize? pageSize,
    PdfOrientation? orientation,
    double? marginMm,
    String? title,
    bool clearTitle = false,
    double? jpegQuality,
    bool? showPageNumbers,
    String? watermarkText,
    bool clearWatermark = false,
    double? watermarkOpacity,
    bool? embedOcrText,
  }) {
    return PdfOptions(
      pageSize: pageSize ?? this.pageSize,
      orientation: orientation ?? this.orientation,
      marginMm: marginMm ?? this.marginMm,
      title: clearTitle ? null : (title ?? this.title),
      jpegQuality: jpegQuality ?? this.jpegQuality,
      showPageNumbers: showPageNumbers ?? this.showPageNumbers,
      watermarkText: clearWatermark ? null : (watermarkText ?? this.watermarkText),
      watermarkOpacity: watermarkOpacity ?? this.watermarkOpacity,
      embedOcrText: embedOcrText ?? this.embedOcrText,
    );
  }
}

class PdfPageInput {
  const PdfPageInput({
    required this.jpegBytes,
    this.width,
    this.height,
    this.channels,
    this.ocrLines,
  });

  final Uint8List jpegBytes;
  final int? width;
  final int? height;
  final int? channels;
  final List<PdfOcrLine>? ocrLines;
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
    required this.ocrLines,
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
  final List<PdfOcrLine> ocrLines;
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

String _utf16BeHexBytes(String text) {
  final buf = StringBuffer('<');
  for (final code in text.codeUnits) {
    buf.write(code.toRadixString(16).toUpperCase().padLeft(4, '0'));
  }
  buf.write('>');
  return buf.toString();
}

bool _isAsciiOnly(String text) {
  for (final code in text.codeUnits) {
    if (code < 0x20 || code > 0x7e) return false;
  }
  return true;
}

String _buildPageContentStream(
  _PagePlan p,
  int pageIndex,
  int totalPages,
  double marginPt,
  bool showPageNumbers,
  bool embedOcrText,
) {
  final buf = StringBuffer();
  buf.write('q\n');
  buf.write('${_fmt(p.drawW)} 0 0 ${_fmt(p.drawH)} ${_fmt(p.x)} ${_fmt(p.y)} cm\n');
  buf.write('/Im0 Do\n');
  buf.write('Q\n');

  if (embedOcrText && p.ocrLines.isNotEmpty) {
    for (final line in p.ocrLines) {
      final clean = line.text.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
      if (clean.isEmpty) continue;
      final l = line.left.clamp(0.0, 1.0);
      final r = line.right.clamp(l, 1.0);
      final t = line.top.clamp(0.0, 1.0);
      final b = line.bottom.clamp(t, 1.0);
      final boxW = math.max(4.0, (r - l) * p.drawW);
      final boxH = math.max(5.0, (b - t) * p.drawH);
      final fontSize = (boxH * 0.85).clamp(4.0, 72.0);
      final pdfX = p.x + l * p.drawW;
      final pdfY = p.y + (1.0 - b) * p.drawH + boxH * 0.12;

      buf.write('BT\n');
      buf.write('3 Tr\n');
      if (_isAsciiOnly(clean)) {
        final estWidth = math.max(1.0, clean.length * fontSize * 0.52);
        final tz = ((boxW / estWidth) * 100.0).clamp(25.0, 400.0);
        buf.write('/F1 ${_fmt(fontSize)} Tf\n');
        buf.write('${_fmt(tz)} Tz\n');
        buf.write('1 0 0 1 ${_fmt(pdfX)} ${_fmt(pdfY)} Tm\n');
        buf.write('${_pdfTextString(clean)} Tj\n');
      } else {
        var unitsWidth = 0.0;
        for (final code in clean.codeUnits) {
          unitsWidth += code <= 0x7e ? 0.55 : 1.0;
        }
        final estWidth = math.max(1.0, unitsWidth * fontSize);
        final tz = ((boxW / estWidth) * 100.0).clamp(25.0, 400.0);
        buf.write('/F2 ${_fmt(fontSize)} Tf\n');
        buf.write('${_fmt(tz)} Tz\n');
        buf.write('1 0 0 1 ${_fmt(pdfX)} ${_fmt(pdfY)} Tm\n');
        buf.write('${_utf16BeHexBytes(clean)} Tj\n');
      }
      buf.write('0 Tr\n');
      buf.write('ET\n');
    }
  }

  if (showPageNumbers) {
    final label = '${pageIndex + 1} / $totalPages';
    const fontSize = 9.0;
    final textW = label.length * fontSize * 0.52;
    final tx = ((p.pageW - textW) / 2.0).clamp(4.0, p.pageW - 10.0);
    final ty = math.max(6.0, math.min(p.y * 0.55, marginPt * 0.45));
    buf.write('BT\n');
    buf.write('0 Tr\n');
    buf.write('0.45 0.45 0.45 rg\n');
    buf.write('/F1 ${_fmt(fontSize)} Tf\n');
    buf.write('1 0 0 1 ${_fmt(tx)} ${_fmt(ty)} Tm\n');
    buf.write('${_pdfTextString(label)} Tj\n');
    buf.write('ET\n');
  }

  return buf.toString();
}

/// 生成多页 PDF（零依赖自写 PDF 1.4，JPEG 直接走 /DCTDecode 内嵌，支持页码与不可见双层 OCR 文本）
Uint8List buildPdf(List<PdfPageInput> pages, [PdfOptions opts = const PdfOptions()]) {
  if (pages.isEmpty) {
    throw StateError('PDF 至少需要 1 页');
  }
  final marginMm = opts.marginMm.isFinite ? opts.marginMm.clamp(0.0, 40.0) : 0.0;
  final title = (opts.title != null && opts.title!.isNotEmpty) ? opts.title! : _defaultTitle;

  final plans = <_PagePlan>[];
  var maxMarginPt = 0.0;
  var usesAsciiFont = opts.showPageNumbers;
  var usesCjkFont = false;

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
    final pageMaxMarginPt = math.max(0.0, math.min(pageW, pageH) / 2.0 - 1.0);
    final marginPt = math.min(marginMm * _mmToPt, pageMaxMarginPt);
    if (marginPt > maxMarginPt) maxMarginPt = marginPt;
    final availW = (pageW - marginPt * 2.0).clamp(0.01, pageW);
    final availH = (pageH - marginPt * 2.0).clamp(0.01, pageH);
    final scale = math.min(availW / imgW, availH / imgH);
    final drawW = math.min(pageW, imgW * scale);
    final drawH = math.min(pageH, imgH * scale);

    final ocrLines = opts.embedOcrText && page.ocrLines != null
        ? page.ocrLines!
        : const <PdfOcrLine>[];
    for (final line in ocrLines) {
      final clean = line.text.trim();
      if (clean.isEmpty) continue;
      if (_isAsciiOnly(clean)) {
        usesAsciiFont = true;
      } else {
        usesCjkFont = true;
      }
    }

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
        ocrLines: ocrLines,
      ),
    );
  }

  var nextObjId = 4;
  final asciiFontId = usesAsciiFont ? nextObjId++ : null;
  final cjkType0Id = usesCjkFont ? nextObjId++ : null;
  final cjkCidFontId = usesCjkFont ? nextObjId++ : null;
  final cjkFontDescId = usesCjkFont ? nextObjId++ : null;
  final cjkToUnicodeId = usesCjkFont ? nextObjId++ : null;

  final basePageObjId = nextObjId;
  int pageObjId(int i) => basePageObjId + i * 3;
  int contentObjId(int i) => basePageObjId + 1 + i * 3;
  int imageObjId(int i) => basePageObjId + 2 + i * 3;
  final objCount = (basePageObjId - 1) + pages.length * 3;

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
    ' /Producer ${_pdfTextString('saomiao-flutter 1.2.0')}'
    ' /Creator ${_pdfTextString('saomiao-flutter')}'
    ' /CreationDate ${_pdfTextString(_pdfDate(DateTime.now()))} >>\n',
  );
  endObj();

  // 可选字体对象
  if (asciiFontId != null) {
    beginObj(asciiFontId);
    writeStr(
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\n',
    );
    endObj();
  }
  if (usesCjkFont) {
    beginObj(cjkType0Id!);
    writeStr(
      '<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light'
      ' /Encoding /Identity-H'
      ' /DescendantFonts [$cjkCidFontId 0 R]'
      ' /ToUnicode $cjkToUnicodeId 0 R >>\n',
    );
    endObj();

    beginObj(cjkCidFontId!);
    writeStr(
      '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light'
      ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>'
      ' /FontDescriptor $cjkFontDescId 0 R /DW 1000 >>\n',
    );
    endObj();

    beginObj(cjkFontDescId!);
    writeStr(
      '<< /Type /FontDescriptor /FontName /STSong-Light /Flags 4'
      ' /FontBBox [0 -200 1000 880] /ItalicAngle 0 /Ascent 880'
      ' /Descent -200 /CapHeight 800 /StemV 80 >>\n',
    );
    endObj();

    const cmapStream = '/CIDInit /ProcSet findresource begin\n'
        '12 dict begin\n'
        'begincmap\n'
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> def\n'
        '/CMapName /Adobe-Identity-UCS def\n'
        '/CMapType 2 def\n'
        '1 begincodespacerange\n'
        '<0000> <FFFF>\n'
        'endcodespacerange\n'
        '1 beginbfrange\n'
        '<0000> <FFFF> <0000>\n'
        'endbfrange\n'
        'endcmap\n'
        'CMapName currentdict /CMap defineresource pop\n'
        'end\n'
        'end\n';
    beginObj(cjkToUnicodeId!);
    writeStr('<< /Length ${cmapStream.length} >>\nstream\n${cmapStream}endstream\n');
    endObj();
  }

  final fontResParts = <String>[
    if (asciiFontId != null) '/F1 $asciiFontId 0 R',
    if (cjkType0Id != null) '/F2 $cjkType0Id 0 R',
  ];
  final fontResource = fontResParts.isEmpty ? '' : ' /Font << ${fontResParts.join(' ')} >>';

  // 每页对象
  for (var i = 0; i < pages.length; i++) {
    final p = plans[i];
    final pId = pageObjId(i);
    final cId = contentObjId(i);
    final iId = imageObjId(i);
    final pageMaxMarginPt = math.max(0.0, math.min(p.pageW, p.pageH) / 2.0 - 1.0);
    final pageMarginPt = math.min(marginMm * _mmToPt, pageMaxMarginPt);

    beginObj(pId);
    writeStr(
      '<< /Type /Page /Parent 2 0 R'
      ' /MediaBox [0 0 ${_fmt(p.pageW)} ${_fmt(p.pageH)}]'
      ' /Resources <<$fontResource /XObject << /Im0 $iId 0 R >> >>'
      ' /Contents $cId 0 R >>\n',
    );
    endObj();

    final content = _buildPageContentStream(
      p,
      i,
      pages.length,
      pageMarginPt,
      opts.showPageNumbers,
      opts.embedOcrText,
    );
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
