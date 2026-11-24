import 'package:flutter/material.dart';

import '../../engine/options.dart';
import '../../state/page_models.dart';
import '../theme.dart';

class ParamsSheetContent extends StatelessWidget {
  const ParamsSheetContent({
    super.key,
    required this.options,
    required this.pageCount,
    required this.canUndo,
    required this.onChange,
    required this.onApplyAll,
    required this.onUndo,
    required this.onReset,
  });

  final ScanOptions options;
  final int pageCount;
  final bool canUndo;
  final void Function(Map<String, Object?> patch, {bool immediate}) onChange;
  final VoidCallback onApplyAll;
  final VoidCallback onUndo;
  final VoidCallback onReset;

  static const List<({String title, List<ParamKey> keys})> _groups = [
    (
      title: '影调',
      keys: [ParamKey.contrast, ParamKey.brightness, ParamKey.gamma, ParamKey.shadow],
    ),
    (
      title: '细节',
      keys: [ParamKey.threshold, ParamKey.sharpen, ParamKey.denoise],
    ),
    (
      title: '输出',
      keys: [ParamKey.maxDim],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in _groups) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final row in kParamRows.where((r) => group.keys.contains(r.key)))
                    _SliderRow(
                      row: row,
                      value: row.readFrom(options),
                      disabled: row.onlyMode != null && row.onlyMode != options.mode,
                      onChanged: (next) =>
                          onChange(<String, Object?>{row.fieldName: next}, immediate: false),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text(
                  '自动纠偏',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                subtitle: const Text(
                  '检测文字行倾角并自动拉直（轻微裁边）',
                  style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
                ),
                value: options.deskew,
                onChanged: (v) =>
                    onChange(<String, Object?>{'deskew': v}, immediate: true),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text(
                  '反相显示',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                subtitle: const Text(
                  '黑底白字与白底黑字互转',
                  style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
                ),
                value: options.invert,
                onChanged: (v) =>
                    onChange(<String, Object?>{'invert': v}, immediate: true),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '改动会实时预览；阈值只在黑白模式下有效。',
          style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: pageCount >= 2 ? onApplyAll : null,
                icon: const Icon(Icons.done_all_rounded, size: 19),
                label: Text('应用到全部页（$pageCount 页）'),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: canUndo ? onUndo : null,
              icon: const Icon(Icons.undo_rounded, size: 18),
              label: const Text('撤销'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onReset,
          icon: const Icon(Icons.restart_alt_rounded, size: 19),
          label: const Text('恢复默认参数'),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.row,
    required this.value,
    required this.disabled,
    required this.onChanged,
  });

  final ParamRowMeta row;
  final int value;
  final bool disabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final divisions = (row.max - row.min) ~/ row.step;
    final clamped = value.clamp(row.min, row.max);
    return Opacity(
      opacity: disabled ? 0.48 : 1,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            SizedBox(
              width: 68,
              child: Text(
                row.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.inkSecondary,
                ),
              ),
            ),
            Expanded(
              child: Slider(
                value: clamped.toDouble(),
                min: row.min.toDouble(),
                max: row.max.toDouble(),
                divisions: divisions > 0 ? divisions : null,
                onChanged: disabled
                    ? null
                    : (v) {
                        final snapped =
                            row.min + (((v - row.min) / row.step).round() * row.step);
                        onChanged(snapped.clamp(row.min, row.max));
                      },
              ),
            ),
            SizedBox(
              width: 66,
              child: Text(
                row.unit.isEmpty ? '$clamped' : '$clamped ${row.unit}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 14,
                  fontFeatures: [FontFeature.tabularFigures()],
                  color: AppColors.inkSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
