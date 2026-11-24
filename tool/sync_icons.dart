import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final root = Directory.current.path;
  final srcAssets = Directory(r'F:\workspace\saomiao-expo\assets');
  final dstAssets = Directory('$root/assets')..createSync(recursive: true);

  for (final name in [
    'icon.png',
    'splash-icon.png',
    'android-icon-foreground.png',
    'android-icon-background.png',
    'android-icon-monochrome.png',
    'favicon.png',
    'logo-mark.svg',
    'icon.svg',
    'logo-lockup.svg',
  ]) {
    final f = File('${srcAssets.path}/$name');
    if (f.existsSync()) {
      f.copySync('${dstAssets.path}/$name');
    }
  }
  final docsLogo = File(r'F:\workspace\saomiao-expo\docs\logo.png');
  if (docsLogo.existsSync()) {
    docsLogo.copySync('${dstAssets.path}/logo.png');
  }

  final masterIcon = img.decodePng(File('${dstAssets.path}/icon.png').readAsBytesSync())!;
  final fgIcon = img.decodePng(File('${dstAssets.path}/android-icon-foreground.png').readAsBytesSync())!;
  final bgIcon = img.decodePng(File('${dstAssets.path}/android-icon-background.png').readAsBytesSync())!;
  final monoIcon = img.decodePng(File('${dstAssets.path}/android-icon-monochrome.png').readAsBytesSync())!;

  img.Image resizeSq(img.Image src, int size) =>
      img.copyResize(src, width: size, height: size, interpolation: img.Interpolation.average);

  // Android mipmaps
  final androidRes = '$root/android/app/src/main/res';
  const androidSizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  for (final e in androidSizes.entries) {
    final out = File('$androidRes/${e.key}/ic_launcher.png')..parent.createSync(recursive: true);
    out.writeAsBytesSync(img.encodePng(resizeSq(masterIcon, e.value)));
  }

  // Android adaptive icon (API 26+)
  final nodpi = Directory('$androidRes/drawable-nodpi')..createSync(recursive: true);
  File('${nodpi.path}/ic_launcher_foreground.png')
      .writeAsBytesSync(img.encodePng(resizeSq(fgIcon, 432)));
  File('${nodpi.path}/ic_launcher_background.png')
      .writeAsBytesSync(img.encodePng(resizeSq(bgIcon, 432)));
  File('${nodpi.path}/ic_launcher_monochrome.png')
      .writeAsBytesSync(img.encodePng(resizeSq(monoIcon, 432)));

  final anydpi = Directory('$androidRes/mipmap-anydpi-v26')..createSync(recursive: true);
  File('${anydpi.path}/ic_launcher.xml').writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''');

  // Web icons
  File('$root/web/favicon.png').writeAsBytesSync(img.encodePng(resizeSq(masterIcon, 48)));
  File('$root/web/icons/Icon-192.png').writeAsBytesSync(img.encodePng(resizeSq(masterIcon, 192)));
  File('$root/web/icons/Icon-512.png').writeAsBytesSync(img.encodePng(resizeSq(masterIcon, 512)));
  File('$root/web/icons/Icon-maskable-192.png').writeAsBytesSync(img.encodePng(resizeSq(masterIcon, 192)));
  File('$root/web/icons/Icon-maskable-512.png').writeAsBytesSync(img.encodePng(resizeSq(masterIcon, 512)));

  // Windows ICO (multi-size 16/32/48/256)
  final icoImg = resizeSq(masterIcon, 256);
  for (final s in [128, 64, 48, 32, 16]) {
    icoImg.addFrame(resizeSq(masterIcon, s));
  }
  File('$root/windows/runner/resources/app_icon.ico')
      .writeAsBytesSync(img.IcoEncoder().encodeImages(icoImg.frames));

  // iOS AppIcons
  final iosDir = '$root/ios/Runner/Assets.xcassets/AppIcon.appiconset';
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
    File('$iosDir/${e.key}').writeAsBytesSync(img.encodePng(resizeSq(masterIcon, e.value)));
  }
  stdout.writeln('Generated all platform icons cleanly.');
}
