import 'package:flutter/material.dart';

import '../../state/page_models.dart';
import '../../state/scanner_controller.dart';
import '../theme.dart';

class DocumentLibrarySheet extends StatefulWidget {
  const DocumentLibrarySheet({
    super.key,
    required this.controller,
  });

  final ScannerController controller;

  @override
  State<DocumentLibrarySheet> createState() => _DocumentLibrarySheetState();
}

class _DocumentLibrarySheetState extends State<DocumentLibrarySheet> {
  String _folderFilter = '全部';
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _showCreateDocDialog() async {
    final initialFolder = _folderFilter == '全部' ? '默认' : _folderFilter;
    final created = await showDialog<({String title, String folder})>(
      context: context,
      builder: (_) => _DocFormDialog(
        dialogTitle: '新建扫描文档',
        initialTitle: '',
        hintText: '例如：租房合同 / 报销发票',
        initialFolder: initialFolder,
        folders: widget.controller.folders,
        confirmLabel: '创建',
      ),
    );
    if (created != null && mounted) {
      await widget.controller.createDocument(
        title: created.title,
        folder: created.folder,
      );
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _showRenameDialog(ScanDocument doc) async {
    final res = await showDialog<({String title, String folder})>(
      context: context,
      builder: (_) => _DocFormDialog(
        dialogTitle: '重命名与分组',
        initialTitle: doc.title,
        hintText: '输入文档名称',
        initialFolder: doc.folder,
        folders: widget.controller.folders,
        confirmLabel: '保存',
      ),
    );
    if (res != null && res.title.isNotEmpty) {
      widget.controller.renameDocument(doc.id, res.title, folder: res.folder);
    }
  }

  Future<void> _showAddFolderDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _SimpleNameDialog(
        title: '新建文件夹分组',
        label: '文件夹名称',
        confirmLabel: '添加',
      ),
    );
    if (name != null && name.isNotEmpty) {
      widget.controller.addCustomFolder(name);
      setState(() => _folderFilter = name);
    }
  }

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final activeId = widget.controller.currentDocument.id;
        final folders = <String>['全部', ...widget.controller.folders];
        final query = _searchQuery.trim().toLowerCase();
        final docs = widget.controller.documents.where((d) {
          if (_folderFilter != '全部' && d.folder != _folderFilter) return false;
          if (query.isNotEmpty &&
              !d.title.toLowerCase().contains(query) &&
              !d.folder.toLowerCase().contains(query)) {
            return false;
          }
          return true;
        }).toList(growable: false);

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              18,
              0,
              18,
              18 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '扫描文档库',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: pal.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '按文件夹分组管理多份扫描文档',
                            style: TextStyle(fontSize: 13, color: pal.inkMuted),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _showCreateDocDialog,
                      icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                      label: const Text('新建文档'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: InputDecoration(
                    hintText: '搜索文档名称或分组…',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                            icon: const Icon(Icons.clear_rounded, size: 18),
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: pal.surfaceLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: pal.outline),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final f in folders) ...[
                        FilterChip(
                          label: Text(f),
                          selected: _folderFilter == f,
                          onSelected: (_) => setState(() => _folderFilter = f),
                        ),
                        const SizedBox(width: 6),
                      ],
                      ActionChip(
                        avatar: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('新建分组'),
                        onPressed: _showAddFolderDialog,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: docs.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Text(
                            '当前筛选条件下暂无文档',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: pal.inkMuted),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: docs.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, idx) {
                            final doc = docs[idx];
                            final active = doc.id == activeId;
                            return InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () async {
                                await widget.controller.switchDocument(doc.id);
                                if (context.mounted) Navigator.of(context).pop();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: active ? pal.accentBg : pal.surfaceLow,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: active ? AppColors.seed : pal.outline,
                                    width: active ? 1.5 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      active ? Icons.folder_open_rounded : Icons.folder_outlined,
                                      color: active ? pal.accentText : pal.inkSecondary,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  doc.title,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w700,
                                                    color: active ? pal.accentText : pal.ink,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: pal.surfaceContainer,
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  doc.folder,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: pal.inkSecondary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${doc.pages.length} 页 · 更新于 ${_formatTime(doc.updatedAt)}',
                                            style: TextStyle(fontSize: 12, color: pal.inkMuted),
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: '文档操作',
                                      onSelected: (action) {
                                        if (action == 'rename') {
                                          _showRenameDialog(doc);
                                        } else if (action == 'merge') {
                                          widget.controller.mergeDocumentIntoCurrent(doc.id);
                                        } else if (action == 'delete') {
                                          widget.controller.deleteDocument(doc.id);
                                        }
                                      },
                                      itemBuilder: (ctx) => [
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text('重命名 / 移动分组'),
                                        ),
                                        if (!active && doc.pages.isNotEmpty)
                                          const PopupMenuItem(
                                            value: 'merge',
                                            child: Text('合并页面到当前文档'),
                                          ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            '删除文档',
                                            style: TextStyle(color: pal.danger),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (widget.controller.hasPages) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: widget.controller.isExporting
                        ? null
                        : () {
                            widget.controller.clearCurrentDocumentPages();
                            Navigator.of(context).pop();
                          },
                    icon: Icon(Icons.layers_clear_outlined, color: pal.danger, size: 18),
                    label: Text(
                      '清空当前文档全部页',
                      style: TextStyle(color: pal.danger),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DocFormDialog extends StatefulWidget {
  const _DocFormDialog({
    required this.dialogTitle,
    required this.initialTitle,
    required this.hintText,
    required this.initialFolder,
    required this.folders,
    required this.confirmLabel,
  });

  final String dialogTitle;
  final String initialTitle;
  final String hintText;
  final String initialFolder;
  final List<String> folders;
  final String confirmLabel;

  @override
  State<_DocFormDialog> createState() => _DocFormDialogState();
}

class _DocFormDialogState extends State<_DocFormDialog> {
  late final TextEditingController _ctrl;
  late String _folder;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialTitle);
    _folder = widget.folders.contains(widget.initialFolder)
        ? widget.initialFolder
        : widget.folders.first;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.dialogTitle),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '文档名称',
                  hintText: widget.hintText,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _folder,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '所属文件夹',
                  border: OutlineInputBorder(),
                ),
                items: widget.folders
                    .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                    .toList(growable: false),
                onChanged: (v) {
                  if (v != null) setState(() => _folder = v);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            (title: _ctrl.text.trim(), folder: _folder),
          ),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _SimpleNameDialog extends StatefulWidget {
  const _SimpleNameDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
  });

  final String title;
  final String label;
  final String confirmLabel;

  @override
  State<_SimpleNameDialog> createState() => _SimpleNameDialogState();
}

class _SimpleNameDialogState extends State<_SimpleNameDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 300,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
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
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
