import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';

class YmHistoryEntry {
  YmHistoryEntry({
    required this.id,
    required this.title,
    required this.author,
    required this.cat,
    required this.kind,
    required this.cover,
    required this.chapterId,
    required this.chapterTitle,
    required this.percent,
    required this.lastReadAt,
    this.page = 0,
    this.pages = 0,
    this.seq = 0,
  });

  final String id;
  final String title;
  final String author;
  final String cat;
  final String kind; // novel / manga
  final String cover;
  final String chapterId;
  final String chapterTitle;
  final double percent;
  final DateTime lastReadAt;
  final int page;
  final int pages;

  /// 单调序号：同一毫秒内连续两条记录的 `lastReadAt` 可能相等，
  /// 历史排序用它兜底，保证「后读的在前」是确定的。
  final int seq;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'author': author,
    'cat': cat,
    'kind': kind,
    'cover': cover,
    'chapterId': chapterId,
    'chapterTitle': chapterTitle,
    'percent': percent,
    'lastReadAt': lastReadAt.millisecondsSinceEpoch,
    'page': page,
    'pages': pages,
    'seq': seq,
  };

  static YmHistoryEntry fromJson(Map<String, Object?> json) {
    return YmHistoryEntry(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      cat: (json['cat'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'novel',
      cover: (json['cover'] as String?) ?? '',
      chapterId: (json['chapterId'] as String?) ?? '',
      chapterTitle: (json['chapterTitle'] as String?) ?? '',
      percent: (json['percent'] as num?)?.toDouble() ?? 0,
      lastReadAt: DateTime.fromMillisecondsSinceEpoch(
        (json['lastReadAt'] as num?)?.toInt() ?? 0,
      ),
      page: (json['page'] as num?)?.toInt() ?? 0,
      pages: (json['pages'] as num?)?.toInt() ?? 0,
      seq: (json['seq'] as num?)?.toInt() ?? 0,
    );
  }
}

class YmShelfEntry {
  const YmShelfEntry({
    required this.id,
    required this.title,
    required this.author,
    required this.kind,
    this.cover = '',
  });
  final String id;
  final String title;
  final String author;
  final String kind; // novel / manga

  /// 封面地址（绝对地址）。旧档没有这个字段，读出为空，靠 [YmLibrary.coverOf] 兜底。
  final String cover;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'author': author,
    'kind': kind,
    'cover': cover,
  };

  static YmShelfEntry fromJson(Map<String, Object?> json) {
    return YmShelfEntry(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'novel',
      cover: (json['cover'] as String?) ?? '',
    );
  }

  YmShelfEntry copyWith({String? cover}) => YmShelfEntry(
    id: id,
    title: title,
    author: author,
    kind: kind,
    cover: cover ?? this.cover,
  );
}

class YmLibrary extends ChangeNotifier {
  YmLibrary();

  static final YmLibrary instance = YmLibrary();

  final Map<String, YmShelfEntry> _shelf = {};
  final Map<String, YmHistoryEntry> _history = {};

  /// 静态与 [_loaded] 一样跟类走：load / resetForTest 是静态方法要读写它。
  static int _historySeq = 0;

  static bool _loaded = false;

  static const String _fileName = 'ym_library.json';

  static File? _file;

  /// 防抖：阅读器翻页会高频 `recordRead`，合并成一次写盘。
  static Timer? _saveTimer;

  static Future<File?> _libraryFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await YmNative.filesDir();
    if (dir == null || dir.isEmpty) return null;
    return _file = File('$dir${Platform.pathSeparator}$_fileName');
  }

  /// 启动时调用：把上次的书架与阅读历史读回来。
  ///
  /// 读不到（首启 / 通道缺失 / 文件损坏）就从空书架开始，**不抛错**。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final shelf = instance._shelf;
    final history = instance._history;
    try {
      final file = await _libraryFile();
      if (file == null || !await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return;

      final savedShelf = json['shelf'];
      if (savedShelf is List<Object?>) {
        for (final item in savedShelf) {
          if (item is Map<String, Object?>) {
            final entry = YmShelfEntry.fromJson(item);
            if (entry.id.isNotEmpty) shelf[entry.id] = entry;
          }
        }
      }
      final savedHistory = json['history'];
      if (savedHistory is List<Object?>) {
        for (final item in savedHistory) {
          if (item is Map<String, Object?>) {
            final entry = YmHistoryEntry.fromJson(item);
            if (entry.id.isNotEmpty) history[entry.id] = entry;
          }
        }
      }
      for (final e in history.values) {
        if (e.seq > _historySeq) _historySeq = e.seq;
      }
      // 旧档的书架条目没存封面：同名阅读记录里有就顺手补上（只补不改盘，等下次变更一起落）。
      for (final id in shelf.keys.toList()) {
        final entry = shelf[id]!;
        if (entry.cover.isNotEmpty) continue;
        final cover = history[id]?.cover ?? '';
        if (cover.isNotEmpty) shelf[id] = entry.copyWith(cover: cover);
      }
    } catch (_) {
      // 坏档不影响启动：当空书架，接下来的操作会覆盖
    }
  }

  /// 落盘（异步、失败不影响内存态）。书架 / 历史每次变更后经 [scheduleSave] 触发。
  static Future<void> _save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final file = await _libraryFile();
      if (file == null) return;
      final payload = <String, Object?>{
        'shelf': instance._shelf.values.map((e) => e.toJson()).toList(),
        'history': instance._history.values.map((e) => e.toJson()).toList(),
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // 写失败只影响「下次启动还记不记得」，不阻塞当前操作
    }
  }

  /// 变更后调用：短防抖合并高频写（翻页），尾部保证落一次盘。
  static void scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _save);
  }

  /// 仅供测试：指定存档文件并复位内存态（`file` 传 null 模拟「通道缺失」降级）。
  @visibleForTesting
  static void resetForTest({File? file}) {
    _saveTimer?.cancel();
    _saveTimer = null;
    _file = file;
    _loaded = false;
    instance._shelf.clear();
    instance._history.clear();
    _historySeq = 0;
  }

  /// 仅供测试：跳过防抖立即落盘。
  @visibleForTesting
  static Future<void> saveNow() => _save();

  List<YmHistoryEntry> get history => _history.values.toList()
    ..sort((a, b) {
      final byTime = b.lastReadAt.compareTo(a.lastReadAt);
      if (byTime != 0) return byTime;
      return b.seq.compareTo(a.seq);
    });

  List<YmShelfEntry> get shelfEntries => _shelf.values.toList();

  Set<String> get shelf => Set.unmodifiable(_shelf.keys.toSet());

  bool onShelf(String id) => _shelf.containsKey(id);

  void toggleShelf(
    String id, {
    String title = '',
    String author = '',
    String kind = 'novel',
    String cover = '',
  }) {
    if (_shelf.remove(id) == null && title.isNotEmpty) {
      _shelf[id] = YmShelfEntry(
        id: id,
        title: title,
        author: author,
        kind: kind,
        cover: cover,
      );
    }
    notifyListeners();
    scheduleSave();
  }

  /// 封面地址（书架 / 历史行共用）。
  ///
  /// 顺序：本条自带的 cover → 同 id 的阅读记录 → 按站点图床路径从 id 推出来。
  /// 最后这条是给「加入书架时还没存 cover」的旧数据兜底（`coverm` 漫画 / `covern` 小说，
  /// 目录按 id 补零后三位一组），推不出来就返回空串，交给占位图。
  String coverOf(String id, String kind, {String cover = ''}) {
    if (cover.isNotEmpty) return cover;
    final fromHistory = _history[id]?.cover ?? '';
    if (fromHistory.isNotEmpty) return fromHistory;
    return _coverFromId(id, kind);
  }

  static final RegExp _numericId = RegExp(r'^\d+$');

  static String _coverFromId(String id, String kind) {
    if (!_numericId.hasMatch(id)) return '';
    final padded = id.padLeft(9, '0');
    final a = padded.substring(0, 3);
    final b = padded.substring(3, 6);
    final c = padded.substring(6);
    final dir = kind == 'manga' ? 'coverm' : 'covern';
    return 'https://www.yamibo.com/$dir/$a/$b/$c.jpg';
  }

  String? lastChapterOf(String id) => _history[id]?.chapterTitle;

  YmHistoryEntry? historyOf(String id) => _history[id];

  void recordRead({
    required String id,
    required String title,
    required String author,
    required String cat,
    required String kind,
    required String chapterTitle,
    required double percent,
    String cover = '',
    String chapterId = '',
    int page = 0,
    int pages = 0,
    bool immediate = false,
  }) {
    _history[id] = YmHistoryEntry(
      id: id,
      title: title,
      author: author,
      cat: cat,
      kind: kind,
      cover: cover,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      percent: percent,
      lastReadAt: DateTime.now(),
      page: page,
      pages: pages,
      seq: ++_historySeq,
    );
    // 早先加进书架、当时没存封面的条目：读到时顺手补上。
    final shelfEntry = _shelf[id];
    if (shelfEntry != null && shelfEntry.cover.isEmpty && cover.isNotEmpty) {
      _shelf[id] = shelfEntry.copyWith(cover: cover);
    }
    notifyListeners();
    // `immediate` 给「退出阅读器」用：那一刻之后没有下一次写盘机会了（进程随时可能被杀），
    // 不能等 300ms 防抖。_save() 自己会掐掉排队中的计时器。
    if (immediate) {
      unawaited(_save());
    } else {
      scheduleSave();
    }
  }

  void removeHistory(String id) {
    _history.remove(id);
    notifyListeners();
    scheduleSave();
  }

  /// 批量移出书架（T22 多选）：只删存在的条目，一次通知、一次落盘。
  void removeFromShelf(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      if (_shelf.remove(id) != null) changed = true;
    }
    if (!changed) return;
    notifyListeners();
    scheduleSave();
  }

  /// 批量删除历史（T22 多选）。
  void removeHistoryItems(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      if (_history.remove(id) != null) changed = true;
    }
    if (!changed) return;
    notifyListeners();
    scheduleSave();
  }

  void clearHistory() {
    _history.clear();
    notifyListeners();
    scheduleSave();
  }
}

// 文字阅读偏好（字号 / 行距 / 简繁 / 翻页模式）已迁到 `reader_prefs.dart`
// （第十五期起独立落盘，ym_reader_prefs.json），引用方请直接 import 它。
