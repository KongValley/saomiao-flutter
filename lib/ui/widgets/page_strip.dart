import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../state/page_models.dart';
import '../theme.dart';

class PageStrip extends StatelessWidget {
  const PageStrip({
    super.key,
    required this.pages,
    required this.currentIndex,
    required this.thumbnailOf,
    required this.onSelect,
    required this.onOpenActions,
    required this.onReorder,
    required this.onAdd,
  });

  final List<PageItem> pages;
  final int currentIndex;
  final Uint8List? Function(String id) thumbnailOf;
  final void Function(int index) onSelect;
  final void Function(PageItem page, int index) onOpenActions;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    return Container(
      height: 100,
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border(top: BorderSide(color: pal.outline)),
      ),
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        buildDefaultDragHandles: false,
        itemCount: pages.length,
        onReorderItem: onReorder,
        proxyDecorator: (child, index, animation) {
          return Material(
            color: Colors.transparent,
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: child,
          );
        },
        footer: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Semantics(
            button: true,
            label: '添加页面',
            child: InkWell(
              onTap: onAdd,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 62,
                height: 78,
                decoration: BoxDecoration(
                  color: pal.surfaceLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: pal.inkMuted.withValues(alpha: 0.45),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_rounded, size: 22, color: pal.inkSecondary),
                    const SizedBox(height: 2),
                    Text(
                      '添加',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: pal.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        itemBuilder: (context, index) {
          final page = pages[index];
          final selected = index == currentIndex;
          final thumbBytes = thumbnailOf(page.id);
          final hasMetaBadge = page.annotations.isNotEmpty || page.ocr != null;

          return ReorderableDelayedDragStartListener(
            key: ValueKey(page.id),
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onSecondaryTap: () => onOpenActions(page, index),
                child: InkWell(
                  onTap: () {
                    if (selected) {
                      onOpenActions(page, index);
                    } else {
                      onSelect(index);
                    }
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 62,
                    height: 78,
                    decoration: BoxDecoration(
                      color: pal.surfaceContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? AppColors.seed : pal.outline,
                        width: selected ? 2.2 : 1.2,
                      ),
                      boxShadow: selected
                          ? [
                              BoxShadow(
                                color: AppColors.seed.withValues(alpha: 0.2),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (thumbBytes != null)
                          Image.memory(
                            thumbBytes,
                            fit: BoxFit.cover,
                            cacheWidth: 180,
                            gaplessPlayback: true,
                          )
                        else
                          const Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        Positioned(
                          left: 4,
                          bottom: 4,
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 20),
                            height: 20,
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.seed
                                  : pal.surface.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(6),
                              border: selected ? null : Border.all(color: pal.outline),
                            ),
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: selected ? Colors.white : pal.inkSecondary,
                              ),
                            ),
                          ),
                        ),
                        if (hasMetaBadge && !selected)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: AppColors.success,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        if (selected)
                          Positioned(
                            top: 3,
                            right: 3,
                            child: GestureDetector(
                              onTap: () => onOpenActions(page, index),
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: AppColors.ink.withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(
                                  Icons.more_horiz_rounded,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
