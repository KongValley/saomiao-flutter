import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const List<String> _requiredMasterIcons = <String>[
  'icon.png',
  'android-icon-foreground.png',
  'android-icon-background.png',
  'android-icon-monochrome.png',
];

const List<String> _syncAssetFiles = <String>[
  'icon.png',
  'splash-icon.png',
  'android-icon-foreground.png',
  'android-icon-background.png',
  'android-icon-monochrome.png',
  'favicon.png',
  'logo-mark.svg',
  'icon.svg',
  'logo-lockup.svg',
];

void main(List<String> args) {
  final root = Directory.current.path;
  final dstAssets = Directory(p.join(root, 'assets'))..createSync(recursive: true);

  var fromLocal = false;
  String? sourceRoot;
  for (final arg in args) {
    if (arg == '--from-local') {
      fromLocal = true;
    } else if (arg.startsWith('--source=')) {
      sourceRoot = arg.substring('--source='.length);
    } else if (!arg.startsWith('-')) {
      sourceRoot = arg;
    }
  }
  sourceRoot ??= Platform.environment['SAOMIAO_EXPO_DIR'];

  if (!fromLocal) {
    if (sourceRoot == null || sourceRoot.trim().isEmpty) {
      stderr.writeln(
        'Error: source directory is required.\n'
        'Usage: dart run tool/sync_icons.dart --source=<saomiao-expo-root>\n'
        '   or: dart run tool/sync_icons.dart --from-local',
      );
      exitCode = 1;
      return;
    }
    final srcDir = Directory(sourceRoot);
    if (!srcDir.existsSync()) {
      stderr.writeln('Error: source directory does not exist: ${srcDir.path}');
      exitCode = 1;
      return;
    }
    final srcAssets = Directory(p.join(srcDir.path, 'assets'));
    if (!srcAssets.existsSync()) {
      stderr.writeln('Error: source assets directory not found: ${srcAssets.path}');
      exitCode = 1;
      return;
    }

    final missing = <String>[];
    for (final name in _syncAssetFiles) {
      final f = File(p.join(srcAssets.path, name));
      if (!f.existsSync()) {
        missing.add(f.path);
      }
    }
    final docsLogo = File(p.join(srcDir.path, 'docs', 'logo.png'));
    if (!docsLogo.existsSync()) {
      missing.add(docsLogo.path);
    }
    if (missing.isNotEmpty) {
      stderr.writeln('Error: missing required source assets:');
      for (final m in missing) {
        stderr.writeln('  - $m');
      }
      exitCode = 1;
      return;
    }

    for (final name in _syncAssetFiles) {
      File(p.join(srcAssets.path, name)).copySync(p.join(dstAssets.path, name));
    }
    docsLogo.copySync(p.join(dstAssets.path, 'logo.png'));
  }

  for (final name in _requiredMasterIcons) {
    final f = File(p.join(dstAssets.path, name));
    if (!f.existsSync()) {
      stderr.writeln('Error: missing local master icon: ${f.path}');
      exitCode = 1;
      return;
    }
  }

  img.Image decodePngRequired(String path) {
    final decoded = img.decodePng(File(path).readAsBytesSync());
    if (decoded == null) {
      throw StateError('Failed to decode PNG: $path');
    }
    return decoded;
  }

  final masterIcon = decodePngRequired(p.join(dstAssets.path, 'icon.png'));
  final fgIcon = decodePngRequired(p.join(dstAssets.path, 'android-icon-foreground.png'));
  final bgIcon = decodePngRequired(p.join(dstAssets.path, 'android-icon-background.png'));
  final monoIcon = decodePngRequired(p.join(dstAssets.path, 'android-icon-monochrome.png'));

  img.Image resizeSq(img.Image src, int size) =>
      img.copyResize(src, width: size, height: size, interpolation: img.Interpolation.average);

  // Android mipmaps
  final androidRes = p.join(root, 'android', 'app', 'src', 'main', 'res');
  const androidSizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  for (final e in androidSizes.entries) {
    final out = File(p.join(androidRes, e.key, 'ic_launcher.png'))
      ..parent.createSync(recursive: true);
    out.writeAsBytesSync(img.encodePng(resizeSq(masterIcon, e.value)));
  }

  // Android adaptive icon (API 26+)
  final nodpi = Directory(p.join(androidRes, 'drawable-nodpi'))..createSync(recursive: true);
  File(p.join(nodpi.path, 'ic_launcher_foreground.png'))
      .writeAsBytesSync(img.encodePng(resizeSq(fgIcon, 432)));
  File(p.join(nodpi.path, 'ic_launcher_background.png'))
      .writeAsBytesSync(img.encodePng(resizeSq(bgIcon, 432)));
  File(p.join(nodpi.path, 'ic_launcher_monochrome.png'))
      .writeAsBytesSync(img.encodePng(resizeSq(monoIcon, 432)));

  final anydpi = Directory(p.join(androidRes, 'mipmap-anydpi-v26'))..createSync(recursive: true);
  File(p.join(anydpi.path, 'ic_launcher.xml')).writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''');

  // Windows ICO (multi-size 16/32/48/256)
  final icoImg = resizeSq(masterIcon, 256);
  for (final s in [128, 64, 48, 32, 16]) {
    icoImg.addFrame(resizeSq(masterIcon, s));
  }
  File(p.join(root, 'windows', 'runner', 'resources', 'app_icon.ico'))
      .writeAsBytesSync(img.IcoEncoder().encodeImages(icoImg.frames));

  // iOS AppIcons
  final iosDir = p.join(root, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset');
  const iosMap = {
    'Icon-App-20x20@1x.png': 20,
    'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58,
    'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40,
    'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
  };
  for (final e in iosMap.entries) {
    File(p.join(iosDir, e.key)).writeAsBytesSync(img.encodePng(resizeSq(masterIcon, e.value)));
  }
  stdout.writeln('Generated all platform icons cleanly.');
}
