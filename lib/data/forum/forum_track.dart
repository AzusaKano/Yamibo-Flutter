import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../native_bridge.dart';

/// 论坛追帖 / 阅读历史的一条本地记录（一条帖子一条）。
///
/// 进度只有一套字段（[lastPid] / [lastFloor] / [lastPage] / [totalPages]），
/// [tracked] 只区分「追帖」与「看过的历史」，不维护第二套进度。
/// 所有字段拿不到就留空 / 0，不编造。
@immutable
class ForumTrackRecord {
  const ForumTrackRecord({
    required this.tid,
    this.title = '',
    this.boardName = '',
    this.author = '',
    this.replies = 0,
    this.lastPid = '',
    this.lastFloor = 0,
    this.lastPage = 0,
    this.totalPages = 0,
    this.lastReadAt = 0,
    this.tracked = false,
    this.savedAt = 0,
    this.readerTocPid = '',
    this.readerTocIndex = 0,
    this.readerTocTitle = '',
    this.readerPercent = 0,
  });

  final String tid;
  final String title;
  final String boardName;
  final String author;
  final int replies;

  /// 最近读到的楼层（只到楼层，不记楼内像素偏移）。
  final String lastPid;
  final int lastFloor;
  final int lastPage;

  /// 阅读器（作品帖按章读）的章进度，与上面的楼层进度**互不覆盖**。
  /// [readerTocPid] 是章目录条目的 pid（不能用标题当身份）；
  /// [readerTocIndex] 是它在本次目录里的下标（0 起）；
  /// [readerPercent] 是章内滚动百分比（0~1）。
  final String readerTocPid;
  final int readerTocIndex;
  final String readerTocTitle;
  final double readerPercent;

  /// 0 = 站点没给总页数（单页帖 / 未知），界面只写「读到 N 楼」，不编页数。
  final int totalPages;

  /// 最近阅读时间（毫秒时间戳，排序与行内右侧时间都用它）。
  final int lastReadAt;

  /// true = 追帖（永不参与容量淘汰；清空历史也保留）。
  final bool tracked;

  /// 记录建立时间（毫秒时间戳）。
  final int savedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'tid': tid,
        'title': title,
        'boardName': boardName,
        'author': author,
        'replies': replies,
        'lastPid': lastPid,
        'lastFloor': lastFloor,
        'lastPage': lastPage,
        'totalPages': totalPages,
        'lastReadAt': lastReadAt,
        'tracked': tracked,
        'savedAt': savedAt,
        'readerTocPid': readerTocPid,
        'readerTocIndex': readerTocIndex,
        'readerTocTitle': readerTocTitle,
        'readerPercent': readerPercent,
      };

  factory ForumTrackRecord.fromJson(Map<String, Object?> json) {
    return ForumTrackRecord(
      tid: (json['tid'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      boardName: (json['boardName'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      replies: (json['replies'] as num?)?.toInt() ?? 0,
      lastPid: (json['lastPid'] as String?) ?? '',
      lastFloor: (json['lastFloor'] as num?)?.toInt() ?? 0,
      lastPage: (json['lastPage'] as num?)?.toInt() ?? 0,
      totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
      lastReadAt: (json['lastReadAt'] as num?)?.toInt() ?? 0,
      tracked: (json['tracked'] as bool?) ?? false,
      savedAt: (json['savedAt'] as num?)?.toInt() ?? 0,
      readerTocPid: (json['readerTocPid'] as String?) ?? '',
      readerTocIndex: (json['readerTocIndex'] as num?)?.toInt() ?? 0,
      readerTocTitle: (json['readerTocTitle'] as String?) ?? '',
      readerPercent: (json['readerPercent'] as num?)?.toDouble() ?? 0,
    );
  }

  ForumTrackRecord copyWith({
    String? title,
    String? boardName,
    String? author,
    int? replies,
    String? lastPid,
    int? lastFloor,
    int? lastPage,
    int? totalPages,
    int? lastReadAt,
    bool? tracked,
    int? savedAt,
    String? readerTocPid,
    int? readerTocIndex,
    String? readerTocTitle,
    double? readerPercent,
  }) {
    return ForumTrackRecord(
      tid: tid,
      title: title ?? this.title,
      boardName: boardName ?? this.boardName,
      author: author ?? this.author,
      replies: replies ?? this.replies,
      lastPid: lastPid ?? this.lastPid,
      lastFloor: lastFloor ?? this.lastFloor,
      lastPage: lastPage ?? this.lastPage,
      totalPages: totalPages ?? this.totalPages,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      tracked: tracked ?? this.tracked,
      savedAt: savedAt ?? this.savedAt,
      readerTocPid: readerTocPid ?? this.readerTocPid,
      readerTocIndex: readerTocIndex ?? this.readerTocIndex,
      readerTocTitle: readerTocTitle ?? this.readerTocTitle,
      readerPercent: readerPercent ?? this.readerPercent,
    );
  }
}

/// 论坛追帖 / 阅读历史store（纯本地，不写站点、不需要登录）。
///
/// 与阅读侧的 `YmLibrary` 同构（单例 + 防抖落盘 + 坏档降级），但两套数据
/// 互不读写：书架第三枚胶囊读这里，本地 / 在线两枚仍读 `YmLibrary`。
class ForumTrackStore extends ChangeNotifier {
  ForumTrackStore._();

  static final ForumTrackStore instance = ForumTrackStore._();

  final Map<String, ForumTrackRecord> _records = <String, ForumTrackRecord>{};

  /// 未追帖记录容量上限，超出按 [ForumTrackRecord.lastReadAt] 淘汰最旧。
  /// 追帖不参与淘汰。
  static const int maxUntracked = 200;

  static const String _fileName = 'ym_forum_track.json';

  static bool _loaded = false;
  static File? _file;

  /// 防抖：滚动会高频 `recordRead`，合并成一次写盘（400ms，与阅读侧 300ms 分开设）。
  static Timer? _saveTimer;

  /// 进度通知节流：`recordRead` 不逐帧通知，最多 500ms 一次，
  /// 保证返回书架 / 历史时读到的是最新进度，又不把界面刷爆。
  static Timer? _notifyTimer;

  static Future<File?> _trackFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await YmNative.filesDir();
    if (dir == null || dir.isEmpty) return null;
    return _file = File('$dir${Platform.pathSeparator}$_fileName');
  }

  /// 启动时调用（main.dart 在 `ForumSession.load()` 之后）：坏档 / 通道缺失按空记录，不抛错。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _trackFile();
      if (file == null || !await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return;
      final saved = json['records'];
      if (saved is! List<Object?>) return;
      for (final item in saved) {
        if (item is! Map<String, Object?>) continue;
        final record = ForumTrackRecord.fromJson(item);
        if (record.tid.isEmpty) continue;
        instance._records[record.tid] = record;
      }
      instance._enforceCapacity();
    } catch (_) {
      // 坏档不影响启动：当空记录，接下来的操作会覆盖
    }
  }

  /// 落盘（异步、失败不影响内存态）。先掐掉排队中的计时器，避免重复写。
  static Future<void> _save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final file = await _trackFile();
      if (file == null) return;
      final payload = <String, Object?>{
        'records': instance._records.values.map((e) => e.toJson()).toList(),
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // 写失败只影响「下次启动还记不记得」，不阻塞当前操作
    }
  }

  static void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _save);
  }

  /// 进度节流通知：已有排队就不重排。立即操作会先掐掉它再直接通知。
  void _scheduleNotify() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 500), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void _notifyNow() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }

  /// 仅供测试：指定存档文件并复位内存态（`file` 传 null 模拟「通道缺失」降级）。
  @visibleForTesting
  static void resetForTest({File? file}) {
    _saveTimer?.cancel();
    _saveTimer = null;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _file = file;
    _loaded = false;
    instance._records.clear();
  }

  /// 仅供测试：跳过防抖即时落盘。
  @visibleForTesting
  static Future<void> saveNow() => _save();

  /* ------------------------------- 读出口 ------------------------------- */

  ForumTrackRecord? recordOf(String tid) => _records[tid];

  bool isTracked(String tid) => _records[tid]?.tracked ?? false;

  /// 全部记录（历史页用），按最近阅读倒序。
  List<ForumTrackRecord> get records {
    final list = _records.values.toList();
    list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    return list;
  }

  /// 追帖（书架第三胶囊用），按最近阅读倒序。
  List<ForumTrackRecord> get trackedRecords =>
      records.where((e) => e.tracked).toList();

  int get trackedCount => _records.values.where((e) => e.tracked).length;

  int get recordCount => _records.length;

  /* ------------------------------- 写入口 ------------------------------- */

  /// 首载成功后回写元数据（title / boardName / 首楼作者 / replies）。
  ///
  /// 只动元数据，不碰进度：从追帖 / 历史进入时保存的楼层不能被这次回写抹掉。
  /// 记录不存在时先建一条空进度记录，等基线 / 滚动补上楼层。
  void updateMeta({
    required String tid,
    String title = '',
    String boardName = '',
    String author = '',
    int replies = 0,
  }) {
    if (tid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _records[tid];
    if (old == null) {
      _records[tid] = ForumTrackRecord(
        tid: tid,
        title: title,
        boardName: boardName,
        author: author,
        replies: replies,
        savedAt: now,
      );
    } else {
      _records[tid] = old.copyWith(
        title: title.isNotEmpty ? title : null,
        boardName: boardName.isNotEmpty ? boardName : null,
        author: author.isNotEmpty ? author : null,
        replies: replies > 0 ? replies : null,
      );
    }
    _enforceCapacity();
    _scheduleSave();
    _scheduleNotify();
  }

  /// 记录阅读进度（到楼层）。滚动、翻页、退出都走这里。
  ///
  /// [immediate] 给「滚动停稳 / 退出帖子」用：那一刻之后没有下一次写盘机会了
  /// （进程随时可能被杀），等不了 400ms 防抖，直接写一次并立即通知。
  void recordRead({
    required String tid,
    required String pid,
    required int floor,
    required int page,
    int totalPages = 0,
    String title = '',
    String boardName = '',
    String author = '',
    int replies = 0,
    bool immediate = false,
  }) {
    if (tid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _records[tid];
    _records[tid] = ForumTrackRecord(
      tid: tid,
      title: title.isNotEmpty ? title : (old?.title ?? ''),
      boardName: boardName.isNotEmpty ? boardName : (old?.boardName ?? ''),
      author: author.isNotEmpty ? author : (old?.author ?? ''),
      replies: replies > 0 ? replies : (old?.replies ?? 0),
      lastPid: pid,
      lastFloor: floor,
      lastPage: page,
      // 单页帖 / 站点没给总页数时，别把已有的总页数抹成 0。
      totalPages: totalPages > 0 ? totalPages : (old?.totalPages ?? 0),
      lastReadAt: now,
      tracked: old?.tracked ?? false,
      savedAt: old?.savedAt ?? now,
      // 楼层进度只动楼层字段：阅读器的章进度原样带过去。
      readerTocPid: old?.readerTocPid ?? '',
      readerTocIndex: old?.readerTocIndex ?? 0,
      readerTocTitle: old?.readerTocTitle ?? '',
      readerPercent: old?.readerPercent ?? 0,
    );
    _enforceCapacity();
    if (immediate) {
      _notifyNow();
      unawaited(_save());
    } else {
      _scheduleNotify();
      _scheduleSave();
    }
  }

  /// 追帖（游客可用，只写本机，不写站点）。已有记录保留进度，只翻 tracked。
  void track({
    required String tid,
    String title = '',
    String boardName = '',
    String author = '',
    int replies = 0,
  }) {
    if (tid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _records[tid];
    _records[tid] = ForumTrackRecord(
      tid: tid,
      title: title.isNotEmpty ? title : (old?.title ?? ''),
      boardName: boardName.isNotEmpty ? boardName : (old?.boardName ?? ''),
      author: author.isNotEmpty ? author : (old?.author ?? ''),
      replies: replies > 0 ? replies : (old?.replies ?? 0),
      lastPid: old?.lastPid ?? '',
      lastFloor: old?.lastFloor ?? 0,
      lastPage: old?.lastPage ?? 0,
      totalPages: old?.totalPages ?? 0,
      lastReadAt: old?.lastReadAt ?? now,
      tracked: true,
      savedAt: old?.savedAt ?? now,
      readerTocPid: old?.readerTocPid ?? '',
      readerTocIndex: old?.readerTocIndex ?? 0,
      readerTocTitle: old?.readerTocTitle ?? '',
      readerPercent: old?.readerPercent ?? 0,
    );
    _notifyNow();
    _scheduleSave();
  }

  /// 记录阅读器（作品帖按章读）的章进度。
  ///
  /// 与 [recordRead] 的分工：两边各写各的字段，互不覆盖——
  /// 普通帖子的楼层进度不受影响，作品帖的章进度也不会被帖子页写入抹掉。
  /// 防抖 / 通知节流 / [immediate] 立即落盘沿用 [recordRead] 同一套。
  void recordReaderProgress({
    required String tid,
    required String tocPid,
    required int tocIndex,
    required String tocTitle,
    required double percent,
    bool immediate = false,
  }) {
    if (tid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _records[tid];
    _records[tid] = ForumTrackRecord(
      tid: tid,
      title: old?.title ?? '',
      boardName: old?.boardName ?? '',
      author: old?.author ?? '',
      replies: old?.replies ?? 0,
      lastPid: old?.lastPid ?? '',
      lastFloor: old?.lastFloor ?? 0,
      lastPage: old?.lastPage ?? 0,
      totalPages: old?.totalPages ?? 0,
      lastReadAt: now,
      tracked: old?.tracked ?? false,
      savedAt: old?.savedAt ?? now,
      readerTocPid: tocPid,
      readerTocIndex: tocIndex < 0 ? 0 : tocIndex,
      readerTocTitle: tocTitle.isNotEmpty ? tocTitle : (old?.readerTocTitle ?? ''),
      readerPercent: percent.isFinite ? percent.clamp(0.0, 1.0).toDouble() : 0,
    );
    _enforceCapacity();
    if (immediate) {
      _notifyNow();
      unawaited(_save());
    } else {
      _scheduleNotify();
      _scheduleSave();
    }
  }

  /// 移出追帖：只清 tracked，记录留在历史，进度保留。
  ///
  /// 移出后这条记录就变成「未追帖」，要参与容量淘汰：不淘汰的话 200 条未追帖
  /// + 1 条追帖时移出，总数会短暂停在 201 条。
  void untrack(String tid) {
    final old = _records[tid];
    if (old == null || !old.tracked) return;
    _records[tid] = old.copyWith(tracked: false);
    _enforceCapacity();
    _notifyNow();
    _scheduleSave();
  }

  /// 整条删除（含进度）。当前界面没有单条删除入口，留作数据层能力。
  void remove(String tid) {
    if (_records.remove(tid) == null) return;
    _notifyNow();
    _scheduleSave();
  }

  /// 清空历史：只删未追帖记录，追帖及其进度保留。
  void clearHistory() {
    final toRemove =
        _records.values.where((e) => !e.tracked).map((e) => e.tid).toList();
    if (toRemove.isEmpty) return;
    for (final tid in toRemove) {
      _records.remove(tid);
    }
    _notifyNow();
    _scheduleSave();
  }

  /// 未追帖记录超过 [maxUntracked] 时按 lastReadAt 淘汰最旧；追帖不参与。
  void _enforceCapacity() {
    final untracked = _records.values.where((e) => !e.tracked).toList();
    if (untracked.length <= maxUntracked) return;
    untracked.sort((a, b) => a.lastReadAt.compareTo(b.lastReadAt));
    final excess = untracked.length - maxUntracked;
    for (var i = 0; i < excess; i++) {
      _records.remove(untracked[i].tid);
    }
  }
}
