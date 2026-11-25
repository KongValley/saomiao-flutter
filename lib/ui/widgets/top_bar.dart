import 'package:flutter/material.dart';

import '../theme.dart';

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.hasPages,
    required this.supportsCamera,
    required this.busy,
    required this.documentTitle,
    required this.themeMode,
    required this.autoDetectOnImport,
    required this.onTakePhoto,
    required this.onBurstCamera,
    required this.onPickGallery,
    required this.onImportPdf,
    required this.onPasteClipboard,
    required this.onOpenLibrary,
    required this.onOpenIdComposer,
    required this.onCycleThemeMode,
    required this.onToggleAutoDetect,
    required this.onLoadDemo,
  });

  final bool hasPages;
  final bool supportsCamera;
  final bool busy;
  final String documentTitle;
  final String themeMode;
  final bool autoDetectOnImport;
  final VoidCallback onTakePhoto;
  final VoidCallback onBurstCamera;
  final VoidCallback onPickGallery;
  final VoidCallback onImportPdf;
  final VoidCallback onPasteClipboard;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenIdComposer;
  final VoidCallback onCycleThemeMode;
  final VoidCallback onToggleAutoDetect;
  final VoidCallback onLoadDemo;

  IconData _themeIcon() {
    switch (themeMode) {
      case 'dark':
        return Icons.dark_mode_outlined;
      case 'light':
        return Icons.light_mode_outlined;
      default:
        return Icons.brightness_auto_outlined;
    }
  }

  String _themeTooltip() {
    switch (themeMode) {
      case 'dark':
        return '深色模式（点击切换为跟随系统）';
      case 'light':
        return '浅色模式（点击切换为深色）';
      default:
        return '跟随系统主题（点击切换为浅色）';
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    return Material(
      color: pal.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final compact = maxW < 380;
          final ultraCompact = maxW < 290;
          final horizPad = ultraCompact ? 10.0 : 16.0;

          return Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: pal.outline)),
            ),
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + 8,
              left: horizPad,
              right: horizPad,
              bottom: 10,
            ),
            child: Row(
              children: [
                Container(
                  width: ultraCompact ? 32 : 38,
                  height: ultraCompact ? 32 : 38,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(ultraCompact ? 9 : 11),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.seed.withValues(alpha: 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.document_scanner_rounded,
                    color: Colors.white,
                    size: ultraCompact ? 18 : 21,
                  ),
                ),
                SizedBox(width: ultraCompact ? 8 : 10),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: onOpenLibrary,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '扫描件工坊',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: pal.ink,
                            height: 1.2,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                hasPages ? documentTitle : '本地扫描 · 离线可用',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: pal.inkMuted,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            if (hasPages)
                              Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 15,
                                color: pal.inkMuted,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (hasPages) ...[
                  if (ultraCompact && supportsCamera)
                    PopupMenuButton<String>(
                      tooltip: '添加页面',
                      enabled: !busy,
                      icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
                      onSelected: (value) {
                        if (value == 'camera') {
                          onTakePhoto();
                        } else if (value == 'burst') {
                          onBurstCamera();
                        } else if (value == 'gallery') {
                          onPickGallery();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'burst',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.burst_mode_outlined),
                            title: Text('连拍扫描'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'camera',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.photo_camera_outlined),
                            title: Text('系统相机拍照'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'gallery',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.add_photo_alternate_outlined),
                            title: Text('从相册/文件添加'),
                          ),
                        ),
                      ],
                    )
                  else ...[
                    if (supportsCamera)
                      IconButton.filledTonal(
                        tooltip: '拍照添加',
                        onPressed: busy ? null : onTakePhoto,
                        icon: const Icon(Icons.photo_camera_outlined, size: 20),
                      ),
                    IconButton.filledTonal(
                      tooltip: '从相册/文件添加',
                      onPressed: busy ? null : onPickGallery,
                      icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
                    ),
                  ],
                ],
                if (!compact && (!hasPages || maxW >= 560)) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '全部处理都在设备本地完成，图片不上传',
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: pal.surfaceLow,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: pal.outline),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            size: 15,
                            color: pal.success,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '不上传',
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
                ],
                if (!ultraCompact)
                  IconButton(
                    tooltip: _themeTooltip(),
                    onPressed: onCycleThemeMode,
                    icon: Icon(_themeIcon(), size: 20),
                  ),
                PopupMenuButton<String>(
                  tooltip: '更多工具',
                  enabled: !busy,
                  icon: const Icon(Icons.more_vert_rounded, size: 21),
                  onSelected: (value) {
                    switch (value) {
                      case 'library':
                        onOpenLibrary();
                      case 'burst':
                        onBurstCamera();
                      case 'id_card':
                        onOpenIdComposer();
                      case 'pdf_import':
                        onImportPdf();
                      case 'paste':
                        onPasteClipboard();
                      case 'auto_crop':
                        onToggleAutoDetect();
                      case 'theme':
                        onCycleThemeMode();
                      case 'demo':
                        onLoadDemo();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'library',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.folder_copy_outlined),
                        title: Text('文档库与分组管理'),
                      ),
                    ),
                    if (supportsCamera)
                      const PopupMenuItem(
                        value: 'burst',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.burst_mode_outlined),
                          title: Text('连续连拍模式'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'id_card',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.credit_card_outlined),
                        title: Text('证件 / 双面拼版'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'pdf_import',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.picture_as_pdf_outlined),
                        title: Text('导入 PDF 漂白重排'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'paste',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.content_paste_go_rounded),
                        title: Text('从剪贴板粘贴'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'auto_crop',
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          autoDetectOnImport
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                        ),
                        title: const Text('导入自动裁边'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'theme',
                      child: ListTile(
                        dense: true,
                        leading: Icon(_themeIcon()),
                        title: const Text('切换明暗主题'),
                      ),
                    ),
                    if (!hasPages)
                      const PopupMenuItem(
                        value: 'demo',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.auto_awesome_outlined),
                          title: Text('加载示例文档'),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
