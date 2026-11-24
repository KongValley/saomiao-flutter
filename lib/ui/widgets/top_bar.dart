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
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.outline)),
        ),
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 8,
          left: 16,
          right: 16,
          bottom: 10,
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(11),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.seed.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.document_scanner_rounded,
                color: Colors.white,
                size: 21,
              ),
            ),
            const SizedBox(width: 10),
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
              const SizedBox(width: 4),
            ],
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
            ),
            if (!hasPages) ...[
              const SizedBox(width: 6),
              IconButton(
                tooltip: '加载示例文档',
                onPressed: busy ? null : onLoadDemo,
                icon: const Icon(Icons.auto_awesome_outlined, size: 20),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
