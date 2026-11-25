import 'dart:async' show unawaited;
import 'dart:math' show max;

import 'package:flutter/material.dart';

import '../../data/cache/download_queue.dart';
import '../../data/cache/ym_cache_store.dart';
import '../../design/pressable.dart';
import '../../design/theme.dart';
import '../../design/widgets/button.dart';
import '../../design/widgets/chip.dart';
import '../../design/widgets/offline_controls.dart' show YmHeaderTextAction;
import '../../design/widgets/sheet.dart';
import '../../design/widgets/toast.dart';

/// 帖子页的「离线保存」弹层。
///
/// 四条硬口径：
/// * **第 1 页默认选中且不可取消** —— 首楼是标题 / 目录 / 楼主正文，只存后几页
///   等于存了半篇。不写「为什么必须下」的解释，选中态本身就是说明；
/// * **已存页同样是选中且不可取消** —— 勾掉已存的页没有任何动作可做
///   （删除在离线内容页），让它可点只会让人猜；
/// * **不估体积**：一页里有多少图不可预知，报页数不报 MB；
/// * 「检查更新」不在这里 —— 它是逐页核对的**重动作**，入口在帖子菜单里
///   （2026-11-25 移出）。本弹层只负责"选哪几页存下来"。
Future<void> showForumOfflineSheet(
  BuildContext context, {
  required String tid,
  required String title,
  required int totalPages,
  required int replies,
}) {
  return showYmSheet<void>(
    context,
    builder: (_) => _ForumOfflineSheet(
      tid: tid,
      title: title,
      totalPages: totalPages,
      replies: replies,
    ),
  );
}

class _ForumOfflineSheet extends StatefulWidget {
  const _ForumOfflineSheet({
    required this.tid,
    required this.title,
    required this.totalPages,
    required this.replies,
  });

  final String tid;
  final String title;

  /// 本次进帖子页时站点给的总页数（0 = 不知道）。
  final int totalPages;

  /// 解析到的回复数，入队时一起记进帖子级记录。
  final int replies;

  @override
  State<_ForumOfflineSheet> createState() => _ForumOfflineSheetState();
}

class _ForumOfflineSheetState extends State<_ForumOfflineSheet> {
  /// 已落账的页（选中且不可取消）。
  final Set<int> _stored = <int>{};

  /// 当前勾选（含第 1 页与已存页这些锁定项）。
  final Set<int> _picked = <int>{};

  /// 可保存的页数上限。
  int _total = 1;

  @override
  void initState() {
    super.initState();
    _stored.addAll(<int>{
      for (final e in YmCache.instance
          .peekOfParent('forum', widget.tid)
          .where((e) => e.state.isDone))
        e.order,
    });
    _total = max(
      widget.totalPages,
      _stored.isEmpty ? 1 : _stored.reduce(max),
    );
    _picked
      ..addAll(_stored)
      ..add(1);
    // 下载进度会变：「已存 N 页」要跟手
    YmCache.instance.addListener(_onCacheChanged);
    YmDownloadQueue.instance.addListener(_onCacheChanged);
  }

  @override
  void dispose() {
    YmCache.instance.removeListener(_onCacheChanged);
    YmDownloadQueue.instance.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    final now = <int>{
      for (final e in YmCache.instance
          .peekOfParent('forum', widget.tid)
          .where((e) => e.state.isDone))
        e.order,
    };
    if (now.length == _stored.length && now.every(_stored.contains)) {
      setState(() {}); // 排队 / 下载中的状态也要刷
      return;
    }
    setState(() {
      _stored
        ..clear()
        ..addAll(now);
      _picked.addAll(now);
      _total = max(_total, now.isEmpty ? 1 : now.reduce(max));
    });
  }

  /// 锁定项：第 1 页 + 已存页。
  bool _locked(int page) => page == 1 || _stored.contains(page);

  /// 真正要下的页（勾选里除去已存的），升序。
  List<int> get _toSave =>
      _picked.where((p) => !_stored.contains(p)).toList()..sort();

  List<int> get _storedSorted => _stored.toList()..sort();

  void _toggle(int page) {
    if (_locked(page)) return; // 点了没反应，按要求不弹任何解释
    setState(() {
      if (!_picked.remove(page)) _picked.add(page);
    });
  }

  /// 「全部 N 页」/「取消全选」：把勾选拉满或清到只剩锁定项。
  void _toggleAll() {
    setState(() {
      final all = _picked.length == _total;
      _picked.clear();
      if (!all) {
        _picked.addAll(<int>[for (var i = 1; i <= _total; i++) i]);
      } else {
        _picked
          ..addAll(_stored)
          ..add(1);
      }
    });
  }

  void _save() {
    final pages = _toSave;
    if (pages.isEmpty) return;
    unawaited(
      YmDownloadQueue.instance.enqueueForum(
        tid: widget.tid,
        title: widget.title,
        pages: pages,
        totalPages: _total,
        replies: widget.replies,
      ),
    );
    // 弹层不关：用户可以接着挑或看进度
    showYmToast(context, '已加入下载');
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final toSave = _toSave;
    final screenH = MediaQuery.sizeOf(context).height;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          14,
          14,
          14,
          14 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const YmSheetHeader(title: '离线保存'),
            if (_stored.isNotEmpty) ...<Widget>[
              Text(
                '已存 ${_stored.length} 页'
                '（第 ${_storedSorted.join('、')} 页）',
                style: c.small12.copyWith(color: c.text2),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '选择要保存的页',
                    style: c.small12.copyWith(color: c.text2),
                  ),
                ),
                YmHeaderTextAction(
                  label: _picked.length == _total ? '取消全选' : '全部 $_total 页',
                  semanticLabel: '勾选全部页',
                  onTap: _toggleAll,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: screenH * 0.45),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (var i = 1; i <= _total; i++)
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,
                        label: '$i',
                        active: _picked.contains(i),
                        compact: true,
                        // 锁定项不给 onTap：点了没反应
                        onTap: _locked(i) ? null : () => _toggle(i),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            YmButton(
              kind: YmButtonKind.primary,
              expanded: true,
              label: toSave.isEmpty ? '已全部保存' : '保存 ${toSave.length} 页',
              onTap: toSave.isEmpty ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
