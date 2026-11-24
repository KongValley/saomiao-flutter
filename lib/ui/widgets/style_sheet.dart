import 'package:flutter/material.dart';

import '../../engine/options.dart';
import '../../state/page_models.dart';
import '../theme.dart';

class StyleSheetContent extends StatelessWidget {
  const StyleSheetContent({
    super.key,
    required this.options,
    required this.onPatch,
  });

  final ScanOptions options;
  final void Function(Map<String, Object?> patch) onPatch;

  IconData _modeIcon(ScanMode mode) {
    switch (mode) {
      case ScanMode.bw:
        return Icons.description_outlined;
      case ScanMode.gray:
        return Icons.image_outlined;
      case ScanMode.color:
        return Icons.auto_awesome_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final paperDisabled = options.mode == ScanMode.bw;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '扫描风格',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.inkMuted,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var i = 0; i < kModeOptions.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: _ModeCard(
                  option: kModeOptions[i],
                  icon: _modeIcon(kModeOptions[i].value),
                  selected: options.mode == kModeOptions[i].value,
                  onTap: () => onPatch(<String, Object?>{'mode': kModeOptions[i].value.value}),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '纸张底色',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.inkMuted,
              ),
            ),
            Text(
              paperDisabled ? '仅灰度 / 彩色模式有效' : '调整纸面色温',
              style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<PaperTone>(
          showSelectedIcon: false,
          segments: kPaperOptions
              .map(
                (p) => ButtonSegment<PaperTone>(
                  value: p.value,
                  label: Text(p.label),
                  enabled: !paperDisabled,
                ),
              )
              .toList(growable: false),
          selected: <PaperTone>{options.paper},
          onSelectionChanged: paperDisabled
              ? null
              : (next) {
                  if (next.isNotEmpty) {
                    onPatch(<String, Object?>{'paper': next.first.value});
                  }
                },
        ),
        const SizedBox(height: 20),
        const Text(
          '一键预设',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.inkMuted,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = (constraints.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: kStylePresets.map((preset) {
                final active = preset.isActive(options);
                return SizedBox(
                  width: cardWidth,
                  child: InkWell(
                    onTap: () => onPatch(preset.patch),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: active ? const Color(0xFFEDF3FF) : AppColors.surfaceLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: active ? AppColors.seed : AppColors.outline,
                          width: active ? 1.5 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            preset.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: active ? const Color(0xFF1D4ED8) : AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            preset.desc,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.inkMuted,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(growable: false),
            );
          },
        ),
        const SizedBox(height: 14),
        const Text(
          '选中的风格会立即应用到当前页，可随时切换。',
          style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.option,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final ModeOption option;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = selected ? const Color(0xFF1D4ED8) : AppColors.inkSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 96),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEDF3FF) : AppColors.surfaceLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.seed : AppColors.outline,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 26, color: selected ? tint : AppColors.inkMuted),
            const SizedBox(height: 6),
            Text(
              option.label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: tint,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              option.hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: selected ? tint : AppColors.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
