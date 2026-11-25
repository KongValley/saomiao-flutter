import 'package:flutter/material.dart';

import '../theme.dart';

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.hasPages,
    required this.supportsCamera,
    required this.busy,
    required this.onTakePhoto,
    required this.onPickGallery,
    required this.onLoadDemo,
  });

  final bool hasPages;
  final bool supportsCamera;
  final bool busy;
  final VoidCallback onTakePhoto;
  final VoidCallback onPickGallery;
  final VoidCallback onLoadDemo;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final compact = maxW < 340;
          final ultraCompact = maxW < 280;
          final horizPad = ultraCompact ? 10.0 : 16.0;

          return Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.outline)),
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
                const Expanded(
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
                          color: AppColors.ink,
                          height: 1.25,
                        ),
                      ),
                      Text(
                        '本地扫描 · 离线可用',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.inkMuted,
                          height: 1.3,
                        ),
                      ),
                    ],
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
                        } else if (value == 'gallery') {
                          onPickGallery();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'camera',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.photo_camera_outlined),
                            title: Text('拍照添加'),
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
                  if (!compact) const SizedBox(width: 4),
                ],
                if (!compact)
                  Tooltip(
                    message: '全部处理都在设备本地完成，图片不上传',
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLow,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.outline),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            size: 15,
                            color: AppColors.success,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '不上传',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.inkSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!ultraCompact)
                  const Tooltip(
                    message: '全部处理都在设备本地完成，图片不上传',
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.verified_user_outlined,
                        size: 18,
                        color: AppColors.success,
                      ),
                    ),
                  ),
                if (!hasPages) ...[
                  SizedBox(width: ultraCompact ? 2 : 6),
                  IconButton(
                    tooltip: '加载示例文档',
                    onPressed: busy ? null : onLoadDemo,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
