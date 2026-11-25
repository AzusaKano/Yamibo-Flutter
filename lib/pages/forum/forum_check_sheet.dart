import 'dart:async' show unawaited;
import 'dart:math' show max;

import 'package:flutter/material.dart';

import '../../data/cache/download_queue.dart';
import '../../data/cache/ym_cache_store.dart';
import '../../data/forum/forum_api.dart';
import '../../design/pressable.dart';
import '../../design/theme.dart';
import '../../design/tokens.dart';
import '../../design/widgets/button.dart';
import '../../design/widgets/sheet.dart';
import '../../design/widgets/toast.dart';

/// 帖子「检查更新」弹层（2026-11-25）。
///
/// 口径（用户拍板）：
/// * **手动开始**：逐页核对是重动作（长篇几十页 = 几十个请求、几百 KB），
///   所以打开弹层只展示**上次**的核对情况，由用户决定要不要真跑；
/// * **检查 = 核对 + 自动更新**：跑完发现"已存页有变化 / 有新增页"就直接入队重下，
///   不再多一次「要不要重下」的确认；
/// * 耗时按页推进，行内就地变「检查中… → 已是最新 / 有变化 / 检查失败」；
/// * 失败只说「第 X 页检查失败」，不写"没检查成功"。
Future<void> showForumCheckSheet(
  BuildContext context, {
  required String tid,
  required String title,
}) {
  return showYmSheet<void>(
    context,
    builder: (_) => _ForumCheckSheet(tid: tid, title: title),
  );
}

class _ForumCheckSheet extends StatefulWidget {
  const _ForumCheckSheet({required this.tid, required this.title});

  final String tid;
  final String title;

  @override
  State<_ForumCheckSheet> createState() => _ForumCheckSheetState();
}

class _ForumCheckSheetState extends State<_ForumCheckSheet> {
  /// 已存页（升序）。
  late final List<int> _pages;
  final Map<int, YmForumPageFp> _fps = <int, YmForumPageFp>{};
  final Map<int, ForumPageCheck> _results = <int, ForumPageCheck>{};

  bool _running = false;
  int _done = 0;
  int _total = 0;

  /// 跑完之后才知道的两个数：站点现在的页数、上次保存的页数。
  int _totalPages = 0;
  int _storedTotal = 0;

  /// 这一轮是否已经跑完（跑完才决定底部按钮与结论行）。
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _pages = <int>[
      for (final e in YmCache.instance
          .peekOfParent('forum', widget.tid)
          .where((e) => e.state.isDone && e.order > 0))
        e.order,
    ]..sort();
    _total = _pages.length;
    unawaited(_loadLastRecord());
  }

  Future<void> _loadLastRecord() async {
    final fps = await YmCache.instance.readForumFingerprints(widget.tid);
    final meta = await YmCache.instance.readMeta('forum', widget.tid) ??
        const <String, String>{};
    if (!mounted) return;
    setState(() {
      _fps
        ..clear()
        ..addAll(fps);
      _storedTotal = int.tryParse(meta['total'] ?? '') ?? 0;
    });
  }

  /// 最近一次成功核对的时间（取已存页里最大的那个）。0 = 从没检查过。
  int get _lastCheckedAt =>
      _fps.values.fold<int>(0, (m, e) => max(m, e.at));

  Future<void> _start() async {
    if (_running) return;
    setState(() {
      _running = true;
      _done = 0;
      _total = _pages.length;
      _finished = false;
      _results.clear();
    });
    try {
      final report = await checkForumThread(
        widget.tid,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _results.addAll(<int, ForumPageCheck>{
          for (final p in report.pages) p.page: p,
        });
        _totalPages = report.totalPages;
        _storedTotal = report.storedTotal;
      });
      await _applyUpdates(report);
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _finished = true;
        });
      }
    }
  }

  /// 核对完就更新（2026-11-25 用户拍板）：变化的已存页重下、新增页补下。
  ///
  /// 入队之后不去等它跑完：队列自己会推通知栏，弹层里的「已存」状态由
  /// `YmCache` 监听驱动；用户关掉弹层也不影响下载。
  Future<void> _applyUpdates(ForumCheckReport report) async {
    final changed = report.changedPages;
    final fresh = report.newPages;
    if (changed.isEmpty && fresh.isEmpty) return;
    final queue = YmDownloadQueue.instance;
    if (changed.isNotEmpty) {
      await queue.enqueueForum(
        tid: widget.tid,
        title: widget.title,
        pages: changed,
        totalPages: max(report.totalPages, _storedTotal),
        redo: true,
      );
    }
    if (fresh.isNotEmpty) {
      await queue.enqueueForum(
        tid: widget.tid,
        title: widget.title,
        pages: fresh,
        totalPages: report.totalPages,
      );
    }
    if (!mounted) return;
    final parts = <String>[
      if (changed.isNotEmpty) '第 ${changed.join('、')} 页有变化',
      if (fresh.isNotEmpty) '新增 ${fresh.length} 页',
    ];
    showYmToast(context, '${parts.join('，')} · 已加入下载');
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final screenH = MediaQuery.sizeOf(context).height;
    final last = _lastCheckedAt;

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
            const YmSheetHeader(title: '检查更新'),
            Text(
              last == 0
                  ? '已存 ${_pages.length} 页 · 还没检查过'
                  : '已存 ${_pages.length} 页 · 上次检查 ${_checkedText(last)}',
              style: c.small12.copyWith(color: c.text2),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: screenH * 0.42),
              child: SingleChildScrollView(
                child: Column(
                  children: <Widget>[
                    for (final page in _pages) _row(c, page),
                  ],
                ),
              ),
            ),
            if (_finished) ...<Widget>[
              const SizedBox(height: 10),
              _conclusion(c),
            ],
            const SizedBox(height: 14),
            YmButton(
              kind: YmButtonKind.primary,
              expanded: true,
              label: _running
                  ? '正在检查 $_done / $_total 页'
                  : (_finished ? '完成' : '开始检查'),
              onTap: _running
                  ? null
                  : (_finished ? () => Navigator.of(context).pop() : _start),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行：第 N 页 + 上次检查时间 + 结论（检查中就地变）。
  Widget _row(YmColors c, int page) {
    final result = _results[page];
    final fp = _fps[page];
    final checking = _running && !_results.containsKey(page);
    final (text, color) = _stateOf(c, page, result, fp, checking);
    return YmPressable(
      kind: YmPressKind.none,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.borderWeak)),
        ),
        child: Row(
          children: <Widget>[
            Text(
              '第 $page 页',
              style: TextStyle(fontSize: YmFont.body14, color: c.text),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                checking
                    ? ''
                    : (result != null
                          ? _checkedText(result.checkedAt, zeroText: '')
                          : _checkedText(fp?.at ?? 0, zeroText: '还没检查过')),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              text,
              style: TextStyle(
                fontSize: YmFont.micro11,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 行尾状态文案与颜色。
  (String, Color) _stateOf(
    YmColors c,
    int page,
    ForumPageCheck? result,
    YmForumPageFp? fp,
    bool checking,
  ) {
    if (checking) return ('检查中…', c.text2);
    if (result != null) {
      return switch (result.result) {
        YmForumPageFp.changed => ('有变化 · 已加入下载', c.brandInk),
        YmForumPageFp.failed => ('检查失败', c.danger),
        YmForumPageFp.first => ('已记录', c.text2),
        _ => ('已是最新', c.text3),
      };
    }
    // 还没跑：只报上次的结论
    return switch (fp?.last) {
      YmForumPageFp.changed => ('上次有变化', c.brandInk),
      YmForumPageFp.failed => ('上次检查失败', c.danger),
      YmForumPageFp.first => ('已记录', c.text3),
      YmForumPageFp.same => ('无变化', c.text3),
      _ => ('', c.text3),
    };
  }

  /// 结论行：新增页 / 失败页各一句，没有就报"已是最新"。
  Widget _conclusion(YmColors c) {
    final changed = <int>[
      for (final e in _results.entries)
        if (e.value.changed) e.key,
    ];
    final failed = <int>[
      for (final e in _results.entries)
        if (e.value.failed) e.key,
    ];
    final fresh = _totalPages > _storedTotal && _storedTotal > 0
        ? <int>[for (var p = _storedTotal + 1; p <= _totalPages; p++) p]
        : const <int>[];
    final lines = <(String, Color)>[
      if (fresh.isNotEmpty)
        ('新增 ${fresh.length} 页（第 ${_range(fresh)} 页）· 已加入下载', c.brandInk),
      if (changed.isNotEmpty)
        ('第 ${changed.join('、')} 页有变化 · 已加入下载', c.brandInk),
      if (failed.isNotEmpty)
        ('第 ${failed.join('、')} 页检查失败', c.danger),
    ];
    if (lines.isEmpty) {
      return Text(
        '已是最新',
        style: c.small12.copyWith(color: c.text2),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (text, color) in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              text,
              style: c.small12.copyWith(color: color),
            ),
          ),
      ],
    );
  }

  /// `6、7、8` → `6–8`（连号折成区间，省得住一行放不下）。
  String _range(List<int> pages) {
    if (pages.length < 2) return pages.join('、');
    final contiguous = <String>[];
    var start = pages.first;
    var prev = pages.first;
    for (final p in pages.skip(1)) {
      if (p == prev + 1) {
        prev = p;
        continue;
      }
      contiguous.add(start == prev ? '$start' : '$start–$prev');
      start = p;
      prev = p;
    }
    contiguous.add(start == prev ? '$start' : '$start–$prev');
    return contiguous.join('、');
  }

  /// 时间人话：今天出时刻、昨天出「昨天 HH:mm」、更早出「M/D」。
  String _checkedText(int unixSeconds, {String zeroText = '—'}) {
    if (unixSeconds <= 0) return zeroText;
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final now = DateTime.now();
    String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
    final hm = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    if (dayKey(dt) == dayKey(now)) return hm;
    if (dayKey(dt) == dayKey(now.subtract(const Duration(days: 1)))) {
      return '昨天 $hm';
    }
    return '${dt.month}/${dt.day}';
  }
}
