import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/cache/download_queue.dart';
import '../../data/cache/ym_cache_store.dart';
import '../../data/models.dart';
import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import 'button.dart';
import 'glyph.dart';
import 'selection.dart';
import 'sheet.dart';

/// 离线下载在**界面侧**的全部口径：体积文案、章节状态、标题行文字动作、
/// 详情页的章节勾选弹层（缓存第一期 1E / 第二期 2E）。
///
/// 为什么集中在一个文件：小说详情页与漫画详情页要用**同一套**状态与
/// 同一套按钮文案，分头写必然有一边漏。数据侧唯一真相仍是 `YmCache` / `YmDownloadQueue`。
///
/// 体积估算（§五 实测：小说一章 44,917 字节 ≈ 45 KB；漫画一话 ≈ 13 MB）：
/// 只用来出「约 X MB」，**一律带「约」** —— 每次章节页都可能不一样长（§七.3）。
const int ymNovelChapterBytes = 45 * 1024;
const int ymMangaChapterBytes = 13 * 1024 * 1024;

int ymEstimateBytes(String source, int chapters) =>
    chapters * (source == 'manga' ? ymMangaChapterBytes : ymNovelChapterBytes);

/// 人话体积：`938 B` / `120 KB` / `4.2 MB` / `1.1 GB`。
///
/// 不四舍五入到「整数 MB 但显示 .0」：一位小数、`.0` 直接去掉，
/// 免得「43.0 MB」这种数字读起来像编的。
String ymBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.round()} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${_oneDecimal(mb)} MB';
  return '${_oneDecimal(mb / 1024)} GB';
}

String _oneDecimal(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// 一个章节 / 一话相对本机的状态（离线相关的每一行都要查，逐帧同步读）。
enum YmChapterOfflineState { none, queued, running, done, failed }

/// 队列里的任务状态优先（更实时），其次是索引；`paused` 当 `none`
/// —— 暂停的章应当重新显示可勾选，勾了就是重下。
YmChapterOfflineState ymChapterOfflineState(String key) {
  for (final task in YmDownloadQueue.instance.tasks) {
    if (task.key != key) continue;
    switch (task.state) {
      case YmCacheState.running:
        return YmChapterOfflineState.running;
      case YmCacheState.queued:
        return YmChapterOfflineState.queued;
      case YmCacheState.done:
        return YmChapterOfflineState.done;
      case YmCacheState.failed:
        return YmChapterOfflineState.failed;
      case YmCacheState.paused:
        break;
    }
  }
  final entry = YmCache.instance.peek(key);
  if (entry == null) return YmChapterOfflineState.none;
  return switch (entry.state) {
    YmCacheState.done => YmChapterOfflineState.done,
    YmCacheState.running => YmChapterOfflineState.running,
    YmCacheState.queued => YmChapterOfflineState.queued,
    YmCacheState.failed => YmChapterOfflineState.failed,
    YmCacheState.paused => YmChapterOfflineState.none,
  };
}

/// 一个作品的离线汇总（离线内容页的行 / 「我的」页的计数都从它来）。
class YmOfflineWork {
  const YmOfflineWork({
    required this.source,
    required this.parent,
    required this.parentTitle,
    required this.done,
    required this.total,
    required this.bytes,
    required this.lastAt,
  });

  final String source;
  final String parent;
  final String parentTitle;

  /// 已存 unit 数：小说 = 章数，漫画 = 话数，论坛 = 页数。
  final int done;

  /// 作品当时的 unit 总数；0 = 不知道（旧档），界面不编分母。
  final int total;
  final int bytes;
  final int lastAt;

  String get key => '$source:$parent';
}

/// 按 parent 聚合已落账的 unit；[source] 传 null = 全部。最近下过的排前面。
List<YmOfflineWork> ymOfflineWorks({String? source}) {
  final groups = <String, List<YmCacheEntry>>{};
  for (final entry in YmCache.instance.peekAll()) {
    if (!entry.state.isDone) continue;
    if (source != null && entry.source != source) continue;
    // 按 **作品** 归组（source + parent），不是按 key：小说 key 里是章节 id，
    // 拿 key 前两段归组会把每章都变成一本「作品」。
    groups
        .putIfAbsent('${entry.source}:${entry.parent}', () => <YmCacheEntry>[])
        .add(entry);
  }
  final out = <YmOfflineWork>[];
  for (final units in groups.values) {
    final head = units.first;
    out.add(
      YmOfflineWork(
        source: head.source,
        parent: head.parent,
        parentTitle: head.parentTitle,
        done: units.length,
        total: units.map((e) => e.total).reduce(math.max),
        bytes: units.fold<int>(0, (sum, e) => sum + e.bytes),
        lastAt: units.map((e) => e.at).reduce(math.max),
      ),
    );
  }
  out.sort((a, b) => b.lastAt - a.lastAt);
  return out;
}

/// 目录标题行右侧的文字动作（「离线」带下载图标 / 「正序 / 倒序」带排序图标）。
///
/// 尺寸逐字照 `YmSectionHeader.action`（dim .6 按下、`sub13Strong` 换 `text2`、
/// 水平 6 / 垂直 8 内距）——因为它就是同一个位置上的东西。
/// **为什么不是直接用 `YmSectionHeader.action`**：小说目录标题行要同时放「排序」和
/// 「离线」两个动作，而 `YmSectionHeader` 只有一个动作位、本期不允许改它本体，
/// 所以在页面里用同一个样式渲染两个。
class YmHeaderTextAction extends StatelessWidget {
  const YmHeaderTextAction({
    super.key,
    required this.label,
    this.onTap,
    this.semanticLabel,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// 文字左侧的可选图标（16px，`text2`）：离线入口用下载托盘，排序用 T18-13 / T18-14。
  final YmGlyphKind? icon;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      radius: BorderRadius.circular(YmRadius.chip),
      onTap: onTap,
      semanticLabel: semanticLabel ?? label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              YmGlyph(kind: icon!, size: 16, color: c.text2),
              const SizedBox(width: 5),
            ],
            Text(label, style: c.sub13Strong.copyWith(color: c.text2)),
          ],
        ),
      ),
    );
  }
}

Set<String> _doneKeys(String source, String parentId) => {
  for (final entry in YmCache.instance.peekOfParent(source, parentId))
    if (entry.state.isDone) entry.key,
};

/// 目录 → 弹层里的行：`String` = 分卷标题，`YmChapterRef` = 章节行。
///
/// 分组逻辑与小说详情页 `_groups()` 逐字同套：卷名相同的**连续段**成一组、
/// 卷名为空（扁平书）不插标题行。同一卷名隔开出现时（站点分卷顺序如此），
/// 与详情页一样各自成组、各有一个标题行。
///
/// 漫画 `chapters` 的 `volume` 恒为空（`parser.dart:652`），所以漫画弹层
/// 拿到的就是一串纯章节行 —— 扁平列表，不插分卷标题（第二期 2E，2026-11-24）。
List<Object> ymChapterRows(List<YmChapterRef> chapters) {
  final out = <Object>[];
  var lastVolume = '';
  for (final ch in chapters) {
    final name = ch.volume;
    if (name.isNotEmpty && name != lastVolume) out.add(name);
    lastVolume = name;
    out.add(ch);
  }
  return out;
}

/* ------------------------------ 章节勾选弹层 ------------------------------ */

/// 小说详情页的「离线」弹层：**按分卷分组、按章勾选，再下载**（缓存第一期 1E）。
///
/// 口径（2026-11-24 用户两次纠偏）：
/// * 目录行上不挂逐章下载按钮，入口只有标题行右侧那枚「离线（带下载图标）」动作；
/// * 弹层里**按分卷分组**，分卷标题行右侧也有勾槽 —— 勾了 = 选中整卷；
/// * 标题行**不带副行**：共 N 章 / 已存 M 章 / 体积这三处数据在目录入口、离线内容页、
///   作品子页都看得到，弹层里再写一遍是重复（2026-11-24 用户要求去掉）。
///
/// 每行右侧的状态一律用文字（不出现行内按钮、不带进度环）：
/// * `已下载` —— 不可勾选；
/// * `排队中` / `下载中` —— 已在队列里，不可勾选（勾了也不会重复入队）；
/// * 空勾槽 —— 可勾选；`上次失败` 的章同样是空勾槽 + 一句「上次失败」，勾了即重下。
Future<void> showYmNovelOfflineSheet(
  BuildContext context, {
  required YmNovelDetail detail,
  required List<YmChapterRef> chapters,
}) {
  return showYmSheet<void>(
    context,
    builder: (_) => _YmOfflinePickList(
      source: 'novel',
      parentId: detail.id,
      parentTitle: detail.title,
      rows: ymChapterRows(chapters),
      chapters: chapters,
      unitLabel: '章',
      estimateBytes: (n) => ymEstimateBytes('novel', n),
      onDownload: (picked) =>
          unawaited(YmDownloadQueue.instance.enqueueNovel(detail, picked)),
    ),
  );
}

/// 漫画详情页的「离线」弹层：**扁平列表、按话勾选**（缓存第二期 2E，2026-11-24）。
///
/// 与小说版只差「没有卷分组」与「单位字是话」：勾选规则、全选、底部估重、
/// 删除行、点下载后不关窗**逐条一致**，所以共用 [_YmOfflinePickList]，不复制一份。
/// 唯一多出的一条：`下载中` 的话在行尾显示「12/38 页」（一话 38 页，页级进度
/// 比「下载中」三个字有用），整话 done 之后才回到「已下载」。
Future<void> showYmMangaOfflineSheet(
  BuildContext context, {
  required YmMangaDetail detail,
}) {
  final chapters = detail.chapters;
  return showYmSheet<void>(
    context,
    builder: (_) => _YmOfflinePickList(
      source: 'manga',
      parentId: detail.id,
      parentTitle: detail.title,
      rows: ymChapterRows(chapters),
      chapters: chapters,
      unitLabel: '话',
      estimateBytes: (n) => ymEstimateBytes('manga', n),
      onDownload: (picked) =>
          unawaited(YmDownloadQueue.instance.enqueueManga(detail, picked)),
    ),
  );
}

/// 两个详情页共用的「勾选 → 下载」面板。
///
/// 参数只差三样：行列表（有没有分卷标题）、单位字、估重函数；其余行为完全一致。
class _YmOfflinePickList extends StatefulWidget {
  const _YmOfflinePickList({
    required this.source,
    required this.parentId,
    required this.parentTitle,
    required this.rows,
    required this.chapters,
    required this.unitLabel,
    required this.estimateBytes,
    required this.onDownload,
  });

  /// `novel` / `manga`（也决定缓存 key 的前缀）。
  final String source;
  final String parentId;
  final String parentTitle;

  /// 行列表：`String` = 分卷标题，`YmChapterRef` = 章节行。漫画没有标题行。
  final List<Object> rows;

  /// 作品的全部章节（算行内序号用）。
  final List<YmChapterRef> chapters;

  /// 单位字：小说「章」、漫画「话」。
  final String unitLabel;

  /// 估重：给定话 / 章数返回字节数（一律带「约」显示）。
  final int Function(int count) estimateBytes;

  /// 真点下载时回调（**调用后弹层仍然开着**，由调用方负责入队）。
  final void Function(List<YmChapterRef> picked) onDownload;

  @override
  State<_YmOfflinePickList> createState() => _YmOfflinePickListState();
}

class _YmOfflinePickListState extends State<_YmOfflinePickList> {
  /// 章节 id → 全书序号（1 起）。行内序号不能靠 indexOf 现算：几百章会变 O(n²)。
  late final Map<String, int> _numberOf;

  /// 勾选要下载的章节 id（只可能是「未存 / 上次失败」的章）。
  final Set<String> _picked = <String>{};

  /// 「章节」/「话」—— 用在计数里（「下载 N 话」「已完成 x / y 话」）。
  String get _plural => widget.source == 'manga' ? '话' : '章节';

  // 四句提示语按 source 写死文案，不硬套「$_plural」：套出来会出现
  // 「全部话都已离线」这种不通顺的句子（2026-11-24）。
  // 2026-11-24 第二轮：漫画的「先勾选要下的话」太口语，改成与小说同构的
  // 「选择要下载的话」（用户原话：小说那个「选择章节后下载」相对还好）。
  String get _hintText => widget.source == 'manga' ? '勾选要下载的话' : '勾选要下载的章节';
  String get _allOfflineText =>
      widget.source == 'manga' ? '每一话都已离线' : '全部章节都已离线';
  String get _needPickText =>
      widget.source == 'manga' ? '选择要下载的话' : '选择章节后下载';
  String get _nothingText =>
      widget.source == 'manga' ? '没有可下载的话' : '没有可下载的章节';

  List<Object> get _rows => widget.rows;

  String _keyOf(YmChapterRef ch) => '${widget.source}:${ch.id}';

  /// 这一章现在能不能勾：已存 / 排队 / 下载中都不行（勾了也不会重复入队）。
  bool _canPick(YmChapterRef ch) {
    final st = ymChapterOfflineState(_keyOf(ch));
    return st == YmChapterOfflineState.none ||
        st == YmChapterOfflineState.failed;
  }

  /// 勾选里**当前真的还能下**的那些（下载完的章会自动从勾选里掉出去）。
  List<YmChapterRef> get _pickedChapters => widget.chapters
      .where((ch) => _picked.contains(ch.id) && _canPick(ch))
      .toList();

  /// 从标题行 [i] 往后取这一卷的所有章（到下一个标题行为止）。
  List<YmChapterRef> _volumeChapters(int i) {
    final out = <YmChapterRef>[];
    for (var j = i + 1; j < _rows.length; j++) {
      final row = _rows[j];
      if (row is! YmChapterRef) break;
      out.add(row);
    }
    return out;
  }

  /// 队列里这一条任务（漫画的页级进度要从它读）。
  YmDownloadTask? _taskOf(String key) {
    for (final t in YmDownloadQueue.instance.tasks) {
      if (t.key == key) return t;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _numberOf = <String, int>{
      for (var i = 0; i < widget.chapters.length; i++)
        widget.chapters[i].id: i + 1,
    };
    // 下载进度 / 已存数会变：弹层要跟手刷新（勾选状态由本层自己管）
    YmCache.instance.addListener(_refresh);
    YmDownloadQueue.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    YmCache.instance.removeListener(_refresh);
    YmDownloadQueue.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _toggle(YmChapterRef ch) {
    setState(() {
      if (!_picked.remove(ch.id)) _picked.add(ch.id);
    });
  }

  /// 勾 / 取消整卷：可勾的章全勾了 ⇒ 全摘；否则全勾上。
  void _toggleVolume(List<YmChapterRef> chapters) {
    final pickable = chapters.where(_canPick).toList();
    if (pickable.isEmpty) return;
    setState(() {
      final allPicked = pickable.every((ch) => _picked.contains(ch.id));
      if (allPicked) {
        _picked.removeAll(pickable.map((ch) => ch.id));
      } else {
        _picked.addAll(pickable.map((ch) => ch.id));
      }
    });
  }

  void _toggleAll(List<YmChapterRef> pickable) {
    setState(() {
      if (_pickedChapters.length == pickable.length) {
        _picked.clear();
      } else {
        _picked
          ..clear()
          ..addAll(pickable.map((ch) => ch.id));
      }
    });
  }

  /// 点「下载 N 章 / N 话」：**弹层不关**（2026-11-24 用户要求）。
  ///
  /// 关掉弹层等于把用户赶出去：想再挑几话得重新进一遍。所以这里只做三件事 ——
  /// 入队、清空勾选、让列表自己刷成「排队中 / 下载中」；关窗与否交给用户。
  ///
  /// 入队里有一次真实落盘（队列快照 + 索引），但不 await：入队自己会先
  /// `notifyListeners` 再写盘，列表马上就有反馈。
  void _download(List<YmChapterRef> picked) {
    if (picked.isEmpty) return;
    widget.onDownload(picked);
    setState(_picked.clear);
  }

  Future<void> _deleteAll(int doneCount, int bytes) async {
    final ok = await showYmConfirm(
      context,
      title: '删除离线内容',
      /* 2026-11-24 第二轮统一措辞：三处删除确认都写「删除 N 项？共 X。」，
         不再各写一套（原来分别是「会删掉《X》已下载的 3 话，释放约…」/
         「删除这 2 本的离线内容？会释放约…」/「删除这 3 话？会释放约…」）。 */
      content: '删除 $doneCount 项？共 ${ymBytes(bytes)}。',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    await YmDownloadQueue.instance.cancelOf(widget.source, widget.parentId);
    await YmCache.instance.removeParent(widget.source, widget.parentId);
    if (mounted) setState(() {});
  }

  /// 状态条文案。小说按「已完成 x / y 章」，漫画按「第 3 话 12/38 页」
  /// （一话 38 页要跑 ~50 秒，章级计数在漫画上几乎不动，页级才跟手）。
  String _statusLine(int doneCount, int total, List<YmDownloadTask> running) {
    if (widget.source == 'manga' && running.isNotEmpty) {
      final t = running.first;
      final progress = t.pagesTotal > 0 && t.pagesDone > 0
          ? '${t.pagesDone}/${t.pagesTotal} 页'
          : '正在取页面';
      return '正在下载 · 第 ${t.order} ${widget.unitLabel} $progress';
    }
    if (running.isEmpty) {
      return '正在下载 · 已完成 $doneCount / $total ${widget.unitLabel}';
    }
    return '正在下载《${running.first.title}》 · 已完成 $doneCount / $total '
        '${widget.unitLabel}';
  }

  /// 行高：章节行 = 上下 10 内距 + 正文行高（至少 20，容得下勾槽）；
  /// 标题行 = 上下内距 + 20。`itemExtentBuilder` 用同一套数，行内容不会溢出。
  double _extentOf(int i, TextScaler scaler) {
    if (_rows[i] is String) {
      return (i == 0 ? 2.0 : 16.0) +
          6 +
          math.max(20, scaler.scale(YmFont.small12) * 1.5);
    }
    return 20 + math.max(20, scaler.scale(YmFont.body14) * 1.4);
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final total = widget.chapters.length;
    final doneCount = _doneKeys(widget.source, widget.parentId).length;
    final bytes = YmCache.instance
        .peekOfParent(widget.source, widget.parentId)
        .where((e) => e.state.isDone)
        .fold<int>(0, (sum, e) => sum + e.bytes);
    final tasks = YmDownloadQueue.instance.tasksOf(
      widget.source,
      widget.parentId,
    );
    final running = tasks
        .where((t) => t.state == YmCacheState.running)
        .toList();
    final activeCount = tasks.where((t) => t.isActive).length;
    final pickable = widget.chapters.where(_canPick).toList();
    final picked = _pickedChapters;
    // 弹层不再自动关（2026-11-24），所以「可勾的全没了」有两种情况，得分开说：
    // 已经排上队正在下 ≠ 全部已离线，套用「全部章节都已离线」就是在骗人。
    // 措辞按 2026-11-24 第二轮改口：不用「都已排上了」这种口语，直接说事实。
    final hintText = pickable.isNotEmpty
        ? _hintText
        : (activeCount > 0 ? '已全部加入下载' : _allOfflineText);
    final scaler = MediaQuery.textScalerOf(context);
    final extents = <double>[
      for (var i = 0; i < _rows.length; i++) _extentOf(i, scaler),
    ];
    final contentH = extents.fold<double>(0, (sum, e) => sum + e);

    // 列表高度：按内容收，章多则封顶。上限先扣掉头部 / 按钮 / 删除行的余量
    // （有「正在下载」那一条时再让 30），避免 Column 溢出。
    final screenH = MediaQuery.sizeOf(context).height;
    final chrome = activeCount > 0 ? 330.0 : 300.0;
    final maxList = (screenH * 0.88 - chrome).clamp(150.0, 450.0);
    final listHeight = math.min(contentH, maxList);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const YmSheetHeader(title: '离线'),
        if (activeCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _statusLine(doneCount, total, running),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: c.micro11.copyWith(color: c.text2),
                  ),
                ),
                YmHeaderTextAction(
                  label: '停止',
                  semanticLabel: '停止下载',
                  onTap: () => YmDownloadQueue.instance.cancelAll(),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  hintText,
                  style: c.small12.copyWith(color: c.text2),
                ),
              ),
              if (pickable.isNotEmpty)
                YmHeaderTextAction(
                  label: picked.length == pickable.length ? '取消全选' : '全选',
                  semanticLabel: '勾选全部可下载的$_plural',
                  onTap: () => _toggleAll(pickable),
                ),
            ],
          ),
        ),
        if (_rows.isNotEmpty)
          SizedBox(
            height: listHeight,
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _rows.length,
              itemExtentBuilder: (i, _) => extents[i],
              itemBuilder: (context, i) => _rowAt(c, i),
            ),
          ),
        const SizedBox(height: 10),
        YmButton(
          kind: YmButtonKind.primary,
          expanded: true,
          label: picked.isEmpty
              ? (pickable.isEmpty
                  ? (activeCount > 0 ? '下载中…' : _nothingText)
                  : _needPickText)
              : '下载 ${picked.length} ${widget.unitLabel} · 约 '
                    '${ymBytes(widget.estimateBytes(picked.length))}',
          onTap: picked.isEmpty ? null : () => _download(picked),
        ),
        if (doneCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: YmPressable(
              kind: YmPressKind.dim,
              dimOpacity: 0.6,
              onTap: () => _deleteAll(doneCount, bytes),
              semanticLabel: '删除这本书的离线内容',
              child: SizedBox(
                height: 40,
                child: Center(
                  child: Text(
                    '删除离线内容（$doneCount ${widget.unitLabel} · '
                    '${ymBytes(bytes)}）',
                    style: TextStyle(
                      fontSize: YmFont.body14,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      color: c.danger,
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// 一行：分卷标题（右侧「选整卷」勾槽）或章节行（序号 + 章名 + 状态位）。
  Widget _rowAt(YmColors c, int i) {
    final row = _rows[i];
    if (row is String) {
      final chapters = _volumeChapters(i);
      final pickable = chapters.where(_canPick).toList();
      final allPicked =
          pickable.isNotEmpty &&
          pickable.every((ch) => _picked.contains(ch.id));
      return Padding(
        padding: EdgeInsets.fromLTRB(15, i == 0 ? 2 : 16, 6, 6),
        child: YmPressable(
          kind: YmPressKind.dim,
          dimOpacity: 0.6,
          enabled: pickable.isNotEmpty,
          onTap: pickable.isEmpty ? null : () => _toggleVolume(chapters),
          semanticLabel: '选中整卷《$row》',
          radius: BorderRadius.circular(YmRadius.chip),
          child: SizedBox(
            height: 20,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    row,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 分卷名＝卡外分组标题：资产包 SlateSettingsGroupTitle 的
                    // 12·w700 → text2（与目录弹层同档）。
                    style: c.small12.copyWith(
                      color: c.text2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: YmSelectMetrics.checkSlot,
                  child: YmSelectionCheck(selected: allPicked),
                ),
                const SizedBox(width: 9),
              ],
            ),
          ),
        ),
      );
    }

    final ch = row as YmChapterRef;
    // 一段分卷的圆角 / 分隔线：与目录弹层同一套（段首圆上、段尾圆下、中间只留分隔线）
    final first = i == 0 || _rows[i - 1] is String;
    final last = i == _rows.length - 1 || _rows[i + 1] is String;
    final shape = BorderRadius.vertical(
      top: Radius.circular(first ? YmRadius.panel : 0),
      bottom: Radius.circular(last ? YmRadius.panel : 0),
    );
    final key = _keyOf(ch);
    final st = ymChapterOfflineState(key);
    final canPick =
        st == YmChapterOfflineState.none || st == YmChapterOfflineState.failed;
    final picked = _picked.contains(ch.id);
    return YmPressable(
      kind: YmPressKind.row,
      radius: shape,
      onTap: canPick ? () => _toggle(ch) : null,
      semanticLabel: canPick
          ? (picked ? '取消勾选《${ch.title}》' : '勾选《${ch.title}》')
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          color: c.cardLift,
          borderRadius: shape,
          border: last ? null : Border(bottom: BorderSide(color: c.borderWeak)),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 28,
              child: Text(
                '${_numberOf[ch.id] ?? 0}',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: YmFont.small12, color: c.text3),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                ch.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: YmFont.body14,
                  // 长清单的**内容行档 500**（与目录弹层同口径）：勾中的那行换
                  // w700 + brandInk 跳出，已下载的整行降到 text3。
                  fontWeight: picked ? FontWeight.w700 : FontWeight.w500,
                  color: picked
                      ? c.brandInk
                      : (st == YmChapterOfflineState.done ? c.text3 : c.text),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _trailing(c, st, picked, key),
          ],
        ),
      ),
    );
  }

  Widget _trailing(
    YmColors c,
    YmChapterOfflineState st,
    bool picked,
    String key,
  ) {
    switch (st) {
      case YmChapterOfflineState.done:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            YmGlyph(kind: YmGlyphKind.downloaded, size: 18, color: c.brandInk),
            const SizedBox(width: 4),
            Text(
              '已下载',
              style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
            ),
          ],
        );
      case YmChapterOfflineState.running:
        // 漫画：一话几十页，行尾写页级进度比「下载中」有用（第二期 2E）。
        // 页数还没数出来（第 1 页原文刚发出去）时仍写「下载中」，不编分母。
        final task = widget.source == 'manga' ? _taskOf(key) : null;
        final pages = task != null && task.pagesTotal > 0 && task.pagesDone > 0
            ? '${task.pagesDone}/${task.pagesTotal} 页'
            : '下载中';
        return Text(
          pages,
          style: TextStyle(fontSize: YmFont.micro11, color: c.text2),
        );
      case YmChapterOfflineState.queued:
        return Text(
          '排队中',
          style: TextStyle(fontSize: YmFont.micro11, color: c.text2),
        );
      case YmChapterOfflineState.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '上次失败',
              style: TextStyle(fontSize: YmFont.micro11, color: c.danger),
            ),
            const SizedBox(width: 8),
            YmSelectionCheck(selected: picked),
          ],
        );
      case YmChapterOfflineState.none:
        return YmSelectionCheck(selected: picked);
    }
  }
}
