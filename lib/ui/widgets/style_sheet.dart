import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/options.dart';
import '../../state/page_models.dart';
import '../theme.dart';

class StyleSheetContent extends StatelessWidget {
  const StyleSheetContent({
    super.key,
    required this.options,
    required this.onPatch,
    this.customPresets = const <CustomPreset>[],
    this.onSaveCustomPreset,
    this.onDeleteCustomPreset,
  });

  final ScanOptions options;
  final void Function(Map<String, Object?> patch) onPatch;
  final List<CustomPreset> customPresets;
  final Future<void> Function(String name)? onSaveCustomPreset;
  final void Function(String id)? onDeleteCustomPreset;

  IconData _modeIcon(ScanMode mode) {
    switch (mode) {
      case ScanMode.bw:
        return Icons.description_outlined;
      case ScanMode.bwStamp:
        return Icons.approval_outlined;
      case ScanMode.gray:
        return Icons.image_outlined;
      case ScanMode.color:
        return Icons.auto_awesome_outlined;
    }
  }

  Future<void> _promptSavePreset(BuildContext context) async {
    if (onSaveCustomPreset == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _SavePresetDialog(),
    );
    if (name != null && name.isNotEmpty) {
      await onSaveCustomPreset!(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final paperDisabled =
        options.mode == ScanMode.bw || options.mode == ScanMode.bwStamp;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '扫描风格',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: pal.inkMuted,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final colCount = constraints.maxWidth >= 320 ? 4 : 2;
            const gap = 8.0;
            final cardW = math.max(
              0.0,
              (constraints.maxWidth - gap * (colCount - 1)) / colCount,
            );
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: kModeOptions.map((opt) {
                return SizedBox(
                  width: cardW,
                  child: _ModeCard(
                    option: opt,
                    icon: _modeIcon(opt.value),
                    selected: options.mode == opt.value,
                    onTap: () => onPatch(<String, Object?>{'mode': opt.value.value}),
                  ),
                );
              }).toList(growable: false),
            );
          },
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '纸张底色',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: pal.inkMuted,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                paperDisabled ? '仅灰度 / 彩色模式有效' : '调整纸面色温',
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 13, color: pal.inkMuted),
              ),
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
        Row(
          children: [
            Expanded(
              child: Text(
                '一键预设',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: pal.inkMuted,
                ),
              ),
            ),
            if (onSaveCustomPreset != null)
              TextButton.icon(
                onPressed: () => _promptSavePreset(context),
                icon: const Icon(Icons.bookmark_add_outlined, size: 17),
                label: const Text('保存为预设'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = math.max(0.0, (constraints.maxWidth - 10) / 2);
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
                        color: active ? pal.accentBg : pal.surfaceLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: active ? AppColors.seed : pal.outline,
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
                              color: active ? pal.accentText : pal.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            preset.desc,
                            style: TextStyle(
                              fontSize: 13,
                              color: pal.inkMuted,
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
        if (customPresets.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '我的预设',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: pal.inkMuted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: customPresets.map((cp) {
              final active = cp.isActive(options);
              return InputChip(
                label: Text(cp.name),
                selected: active,
                onPressed: () => onPatch(cp.patch),
                onDeleted: onDeleteCustomPreset == null
                    ? null
                    : () => onDeleteCustomPreset!(cp.id),
              );
            }).toList(growable: false),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          '选中的风格会立即应用到当前页，可随时切换。',
          style: TextStyle(fontSize: 13, color: pal.inkMuted),
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
    final pal = AppColors.of(context);
    final tint = selected ? pal.accentText : pal.inkSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 88),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? pal.accentBg : pal.surfaceLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.seed : pal.outline,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: selected ? tint : pal.inkMuted),
            const SizedBox(height: 5),
            Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: tint,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              option.hint,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: selected ? tint : pal.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavePresetDialog extends StatefulWidget {
  const _SavePresetDialog();

  @override
  State<_SavePresetDialog> createState() => _SavePresetDialogState();
}

class _SavePresetDialogState extends State<_SavePresetDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('保存当前参数为预设'),
      content: SizedBox(
        width: 300,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '预设名称',
            hintText: '例如：高清发票 / 淡字合同',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
