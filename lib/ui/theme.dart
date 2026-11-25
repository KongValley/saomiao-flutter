import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  static const Color seed = Color(0xFF2563EB);
  static const Color bg = Color(0xFFF5F7FB);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceLow = Color(0xFFF7F9FD);
  static const Color surfaceContainer = Color(0xFFEEF2F9);
  static const Color surfaceHigh = Color(0xFFE4EAF4);
  static const Color outline = Color(0xFFDCE4F0);
  static const Color ink = Color(0xFF101A2C);
  static const Color inkSecondary = Color(0xFF4A5B72);
  static const Color inkMuted = Color(0xFF7D8CA3);
  static const Color previewBg = Color(0xFFE9EEF7);
  static const Color success = Color(0xFF0F9D6E);
  static const Color warn = Color(0xFFB4802A);
  static const Color danger = Color(0xFFD93A3A);
  static const Color darkStage = Color(0xFF0B1220);

  static AppThemePalette of(BuildContext context) {
    return Theme.of(context).extension<AppThemePalette>() ?? AppThemePalette.light;
  }
}

class AppThemePalette extends ThemeExtension<AppThemePalette> {
  const AppThemePalette({
    required this.bg,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceContainer,
    required this.surfaceHigh,
    required this.outline,
    required this.ink,
    required this.inkSecondary,
    required this.inkMuted,
    required this.previewBg,
    required this.accentBg,
    required this.accentText,
    required this.success,
    required this.warn,
    required this.danger,
  });

  final Color bg;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceContainer;
  final Color surfaceHigh;
  final Color outline;
  final Color ink;
  final Color inkSecondary;
  final Color inkMuted;
  final Color previewBg;
  final Color accentBg;
  final Color accentText;
  final Color success;
  final Color warn;
  final Color danger;

  static const AppThemePalette light = AppThemePalette(
    bg: AppColors.bg,
    surface: AppColors.surface,
    surfaceLow: AppColors.surfaceLow,
    surfaceContainer: AppColors.surfaceContainer,
    surfaceHigh: AppColors.surfaceHigh,
    outline: AppColors.outline,
    ink: AppColors.ink,
    inkSecondary: AppColors.inkSecondary,
    inkMuted: AppColors.inkMuted,
    previewBg: AppColors.previewBg,
    accentBg: Color(0xFFEDF3FF),
    accentText: Color(0xFF1D4ED8),
    success: AppColors.success,
    warn: AppColors.warn,
    danger: AppColors.danger,
  );

  static const AppThemePalette dark = AppThemePalette(
    bg: Color(0xFF0B1120),
    surface: Color(0xFF111827),
    surfaceLow: Color(0xFF172033),
    surfaceContainer: Color(0xFF1E293B),
    surfaceHigh: Color(0xFF283548),
    outline: Color(0xFF2E3C52),
    ink: Color(0xFFF1F5F9),
    inkSecondary: Color(0xFFCBD5E1),
    inkMuted: Color(0xFF94A3B8),
    previewBg: Color(0xFF080D18),
    accentBg: Color(0xFF172B4D),
    accentText: Color(0xFF93C5FD),
    success: Color(0xFF34D399),
    warn: Color(0xFFFBBF24),
    danger: Color(0xFFF87171),
  );

  @override
  AppThemePalette copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceLow,
    Color? surfaceContainer,
    Color? surfaceHigh,
    Color? outline,
    Color? ink,
    Color? inkSecondary,
    Color? inkMuted,
    Color? previewBg,
    Color? accentBg,
    Color? accentText,
    Color? success,
    Color? warn,
    Color? danger,
  }) {
    return AppThemePalette(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceLow: surfaceLow ?? this.surfaceLow,
      surfaceContainer: surfaceContainer ?? this.surfaceContainer,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      outline: outline ?? this.outline,
      ink: ink ?? this.ink,
      inkSecondary: inkSecondary ?? this.inkSecondary,
      inkMuted: inkMuted ?? this.inkMuted,
      previewBg: previewBg ?? this.previewBg,
      accentBg: accentBg ?? this.accentBg,
      accentText: accentText ?? this.accentText,
      success: success ?? this.success,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
    );
  }

  @override
  AppThemePalette lerp(ThemeExtension<AppThemePalette>? other, double t) {
    if (other is! AppThemePalette) return this;
    return AppThemePalette(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceLow: Color.lerp(surfaceLow, other.surfaceLow, t)!,
      surfaceContainer: Color.lerp(surfaceContainer, other.surfaceContainer, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkSecondary: Color.lerp(inkSecondary, other.inkSecondary, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      previewBg: Color.lerp(previewBg, other.previewBg, t)!,
      accentBg: Color.lerp(accentBg, other.accentBg, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      success: Color.lerp(success, other.success, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

ThemeData _buildThemeFromPalette(AppThemePalette p, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final baseScheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: brightness,
  ).copyWith(
    primary: isDark ? const Color(0xFF60A5FA) : AppColors.seed,
    onPrimary: isDark ? const Color(0xFF0A1628) : Colors.white,
    primaryContainer: p.accentBg,
    onPrimaryContainer: p.accentText,
    surface: p.surface,
    onSurface: p.ink,
    onSurfaceVariant: p.inkSecondary,
    surfaceContainerLowest: p.surface,
    surfaceContainerLow: p.surfaceLow,
    surfaceContainer: p.surfaceContainer,
    surfaceContainerHigh: p.surfaceHigh,
    outline: p.inkMuted,
    outlineVariant: p.outline,
    error: p.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: baseScheme,
    scaffoldBackgroundColor: p.bg,
    extensions: <ThemeExtension<dynamic>>[p],
    dividerTheme: DividerThemeData(
      color: p.outline,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: p.surfaceLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: p.outline),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: BorderSide(color: p.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStateProperty.all(const Size(0, 44)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        side: WidgetStateProperty.all(BorderSide(color: p.outline)),
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accentBg,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? p.accentText : p.inkSecondary,
        );
      }),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: baseScheme.primary,
      inactiveTrackColor: p.surfaceHigh,
      thumbColor: baseScheme.primary,
      trackHeight: 4,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: isDark ? const Color(0xFF1E293B) : AppColors.ink,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

ThemeData buildAppTheme() => _buildThemeFromPalette(AppThemePalette.light, Brightness.light);
ThemeData buildDarkTheme() => _buildThemeFromPalette(AppThemePalette.dark, Brightness.dark);
