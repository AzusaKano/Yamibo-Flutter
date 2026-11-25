import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../native_bridge.dart';

/// 磁盘缓存单元的状态（口径见《缓存第一期》§2.4）。
///
/// **只有 [done] 参与容量统计与「离线可用」判定**：排队 / 下载中 / 失败 / 暂停
/// 都只是「用户表达过意图」，不代表本机真有可读的字节。
enum YmCacheState {
  queued,
  running,
  done,
  failed,
  paused;

  static YmCacheState parse(Object? raw) => switch (raw) {
    'running' => YmCacheState.running,
    'done' => YmCacheState.done,
    'failed' => YmCacheState.failed,
    'paused' => YmCacheState.paused,
    _ => YmCacheState.queued,
  };

  bool get isDone => this == YmCacheState.done;

  /// 还在队列里（含正在下载）：界面上这两态共用一枚进度环。
  bool get isPending =>
      this == YmCacheState.queued || this == YmCacheState.running;

  bool get isTerminal => isDone || this == YmCacheState.failed;
}

/// 索引里的一条 unit。**按 unit 聚合、不按页记**：一话 38 页只写一条，
/// 减少写盘频率（§2.4）。
class YmCacheEntry {
  YmCacheEntry({
    required this.key,
    required this.source,
    required this.parent,
    this.parentTitle = '',
    this.title = '',
    this.pages = 1,
    this.total = 0,
    this.order = 0,
    this.bytes = 0,
    this.at = 0,
    this.state = YmCacheState.queued,
  });

  /// `novel:<chaptId>` / `manga:<chaptId>` / `forum:<tid>:<page>`。
  final String key;

  /// `novel` / `manga` / `forum`（= key 的第一段）。
  final String source;

  /// 作品 id（小说 / 漫画）或帖子 tid（论坛）。
  final String parent;

  /// 作品名 / 帖子标题，给离线内容页显示用，不参与还原。
  String parentTitle;

  /// 章节名（`第1章 一切的开始`）/ 页码。
  String title;

  /// 该 unit 的页数：小说恒 1，漫画 = 一话页数，论坛恒 1。**下载时顺手记下**。
  int pages;

  /// 作品当时的总章数 / 帖子总页数。0 = 不知道（旧档 / 抓不到就留 0，
  /// 界面据此退回「已存 N 章」，不编分母）。
  int total;

  /// 在作品里的序号（1 基），离线内容子页按它排，不依赖文件名里的 id。
  int order;

  /// 实际占用（字节），只有 downloaded 完成后才累加。
  int bytes;

  /// 完成时间（unix 秒），LRU 淘汰用它。
  int at;

  YmCacheState state;

  /// key 里冒号后面那一段（章节 id / 页码），方便按 id 查。
  String get id {
    final i = key.indexOf(':');
    return i < 0 ? key : key.substring(i + 1);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'source': source,
    'parent': parent,
    'parentTitle': parentTitle,
    'title': title,
    'pages': pages,
    'total': total,
    'order': order,
    'bytes': bytes,
    'at': at,
    'state': state.name,
  };

  static YmCacheEntry fromJson(Map<String, Object?> json) {
    final key = (json['key'] as String?) ?? '';
    return YmCacheEntry(
      key: key,
      source: (json['source'] as String?) ?? key.split(':').first,
      parent: (json['parent'] as String?) ?? '',
      parentTitle: (json['parentTitle'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      pages: (json['pages'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      order: (json['order'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      at: (json['at'] as num?)?.toInt() ?? 0,
      state: YmCacheState.parse(json['state']),
    );
  }

  YmCacheEntry copyWith({
    String? parentTitle,
    String? title,
    int? pages,
    int? total,
    int? order,
    int? bytes,
    int? at,
    YmCacheState? state,
  }) => YmCacheEntry(
    key: key,
    source: source,
    parent: parent,
    parentTitle: parentTitle ?? this.parentTitle,
    title: title ?? this.title,
    pages: pages ?? this.pages,
    total: total ?? this.total,
    order: order ?? this.order,
    bytes: bytes ?? this.bytes,
    at: at ?? this.at,
    state: state ?? this.state,
  );
}

/// 论坛某一页的「内容指纹 + 上次检查」记录（`forum/<tid>/fp.json` 的一条）。
///
/// 三个字段各管一件事，别混：
/// * [fp] = **本机这份内容**的指纹，只有下载 / 刷新（内容真的变了）才重写；
/// * [at] = **上次成功核对完**的时间（unix 秒），0 = 还没检查过；
/// * [last] = 上次核对的结论：`same` / `changed` / `failed` / `first`（首次记录基线），
///   空串 = 没检查过。
///
/// ⚠ 检查**不重写 [fp]**：否则"发现第 2 页变了"会在同一个动作里把基线推进，
/// 用户没点重下就再也看不到这条提示了。
class YmForumPageFp {
  const YmForumPageFp({required this.fp, this.at = 0, this.last = ''});

  final String fp;
  final int at;
  final String last;

  static const String same = 'same';
  static const String changed = 'changed';
  static const String failed = 'failed';
  static const String first = 'first';
}

/// 磁盘缓存（第一期的「存储层 + 索引 + 容量」三件事，§2.1 的磁盘层）。
///
/// 口径（2026-11-23 用户拍板，四期共用）：
/// * **存原文，不存模型**：磁盘上只有站点返回的 HTML 与图片字节，读出来重新走 parser
///   （parser 是纯函数、毫秒级；存模型则模型一加字段就要写版本迁移）；
/// * 目录全在 `YmNative.filesDir()` 下的 `ym_cache/`，索引 `index.json` 是**唯一真相**
///   （容量统计、离线判定都读它，不扫目录）；
/// * 所有写入先写 `.tmp` 再 rename，避免进程被杀留下半截文件被当成有效缓存；
/// * 坏档 / 缺目录一律当空，不抛（与 `YmLibrary.load()` 同一套降级口径）。
///
/// ⚠ 只有**下载任务**写盘。随手读一次不落盘 —— 这是「手动下载」口径的直接后果（§2.5）。
class YmCache extends ChangeNotifier {
  YmCache._();

  static final YmCache instance = YmCache._();

  /// `YmNative.filesDir()` 下的子目录名。
  static const String dirName = 'ym_cache';

  static const String indexName = 'index.json';

  /// 容量上限：**没有**（2026-11-24 用户拍板，第十九期改口）。
  ///
  /// 第一期的 2GB 常量与「超限删最旧」已整段删除。理由：离线内容是用户
  /// **主动下载**、留着离线看的东西，程序不该悄悄替他删。空间够不够由手机
  /// 自己决定 —— 写盘失败就按「这一页/这一章失败」如实报，不伪造一句「空间不足」。
  ///
  /// 想统计用量的地方继续用 [usedBytes] / [totalBytes]；它们只累加，不再删东西。

  /// 索引格式版本。改结构才动它；只加字段不动版本（读侧全都带默认值）。
  static const int indexVersion = 1;

  static bool _loaded = false;
  static Future<void>? _loading;

  /// 测试注入目录；null = 走原生通道。
  static Directory? _testDir;

  /// 解析过的真实目录（原生通道每次调用都要过一次 MethodChannel，缓存住）。
  static Directory? _resolvedDir;

  static final Map<String, YmCacheEntry> _units = <String, YmCacheEntry>{};

  /* ------------------------------ 目录与路径 ----------------------------- */

  static Future<Directory?> _cacheDir() async {
    final test = _testDir;
    if (test != null) return test;
    final cached = _resolvedDir;
    if (cached != null) return cached;
    final base = await YmNative.filesDir();
    if (base == null || base.isEmpty) return null;
    return _resolvedDir =
        Directory('$base${Platform.pathSeparator}$dirName');
  }

  /// 已经解析好的目录（null = 还没就绪 / 测试里没有原生通道）。
  static Directory? get _readyDir => _testDir ?? _resolvedDir;

  /// 目录就绪了没有（真机上是启动时 `main` 里 `YmCache.load()` 之后为 true）。
  ///
  /// 给「读侧」判断用：没就绪就别去等原生通道，直接当「没有缓存」——
  /// 否则 widget 测试里通道不回，页面会卡在 loading。
  bool get dirReady => _readyDir != null;

  /// 索引已经读进内存了没有（`main` 里 `YmCache.load()` 之后为 true）。
  ///
  /// 读侧用它避开「为了一本没下过的书去异步读索引」：索引没进来 = 这台机器上
  /// 现在没有已存章节，直接当没有，别把详情页首屏卡在 loading 上。
  bool get indexLoaded => _loaded;

  /// **读路径专用**：只认已解析好的目录，不 await 原生通道。
  ///
  /// 为什么：`fetchChapter` 每章都要查一次磁盘，如果这里去等
  /// `YmNative.filesDir()` 的 Future，一旦通道不回（widget 测试里就是如此）
  /// 整个阅读会被挂住。目录由启动时的 [load] 或任意写盘先解析好；
  /// 没就绪就当没有缓存、照常回源 —— 与「缓存可以没有」的定位一致。
  static File? _readyFileOf(String key) {
    final dir = _readyDir;
    if (dir == null) return null;
    final rel = relativePathOf(key);
    if (rel == null) return null;
    return File('${dir.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}');
  }

  /// key → 相对路径。**唯一出处**：读写、删除、测试都走它，别各处自己拼。
  static String? relativePathOf(String key) {
    final parts = key.split(':');
    if (parts.length < 2) return null;
    final source = parts[0];
    final id = _safeName(parts[1]);
    if (id.isEmpty) return null;
    return switch (source) {
      'novel' => 'novel/$id.html',
      // 漫画按页落盘（2026-11-24 修）：一话 38 页，两段式 `manga/<id>.html`
      // 会让第 2 页直接盖掉第 1 页。第一期小说只用两段 key，所以没暴露。
      // 两段 key（`manga:<chaptId>`，索引里的 unit key）没有单文件，返回 null。
      'manga' => parts.length >= 3
          ? 'manga/$id/${_safeName(parts[2])}.html'
          : null,
      'forum' => parts.length >= 3 ? 'forum/$id/${_safeName(parts[2])}.html' : null,
      _ => null,
    };
  }

  /// 漫画页图的相对路径（`manga/<chaptId>/<page>.jpg`）。
  ///
  /// **page 是 1 基**：阅读器、写盘、删除三处必须同一个口径，错一位就是
  /// 「翻到第 2 页看到第 1 页的图」。
  static String? relativeImagePathOf(String chaptId, int page) {
    final id = _safeName(chaptId);
    if (id.isEmpty || page < 1) return null;
    return 'manga/$id/$page.jpg';
  }

  /// 文件名只留安全字符：id 来自站点（数字为主），但不允许它把路径带歪。
  static String _safeName(String raw) =>
      raw.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_');

  /// unit 的数据文件（不存在也能拿到路径）。会先把目录解析好（写 / 删用）。
  static Future<File?> fileOf(String key) async {
    await _cacheDir();
    return _readyFileOf(key);
  }

  /// `ym_cache/` 下的其它文件（`queue.json` 等），队列层也用这个入口。
  static Future<File?> fileNamed(String name) async {
    final dir = await _cacheDir();
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /* -------------------------------- 载入 -------------------------------- */

  /// 启动时调一次。读不到 / 坏档 ⇒ 当空索引，**不抛**。
  static Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _doLoad();
  }

  static Future<void> _doLoad() async {
    _loaded = true;
    _units.clear();
    try {
      final file = await fileNamed(indexName);
      if (file == null || !await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return;
      final list = json['units'];
      if (list is! List<Object?>) return;
      for (final item in list) {
        if (item is! Map<String, Object?>) continue;
        final entry = YmCacheEntry.fromJson(item);
        if (entry.key.isEmpty) continue;
        _units[entry.key] = entry;
      }
    } catch (_) {
      // 坏档：当空缓存，接下来的写入会覆盖掉它
      _units.clear();
    }
  }

  static Future<void> _ensure() => load();

  Future<void> _saveIndex() async {
    final file = await fileNamed(indexName);
    if (file == null) return;
    try {
      final payload = <String, Object?>{
        'version': indexVersion,
        'units': _units.values.map((e) => e.toJson()).toList(),
      };
      await _atomicWrite(file, jsonEncode(payload));
    } catch (_) {
      // 写失败只影响「下次启动还记不记得」，不阻塞当前操作
    }
  }

  /// 原子写：先 `.tmp` 再 rename（§6.6）。
  ///
  /// Windows 上目标已存在时 rename 会失败（POSIX / Android 会直接覆盖），
  /// 所以只在失败时补一次「删旧再改名」。半截文件永远只以 `.tmp` 的名字存在。
  static Future<void> _atomicWrite(File target, String content) async {
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    }
  }

  /// 给同目录其它落盘件（`queue.json`）复用同一套原子写，别各写一份。
  static Future<void> atomicJsonWrite(File target, String content) =>
      _atomicWrite(target, content);

  /// 字节版原子写（页图用）。与 [_atomicWrite] 同一套 `.tmp` + rename：
  /// 进程被杀时只会留下 `.tmp`，不会被当成有效缓存读出来。
  static Future<void> _atomicWriteBytes(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    }
  }

  /* ------------------------------ 读 / 写原文 ----------------------------- */

  /// 按 key 读原文；不存在 / 读失败返回 null（调用方当未命中，静默回源）。
  ///
  /// **不 await 目录解析、不 await 索引载入**：阅读路径上的这一步必须是「本地一次
  /// 文件读」，不能变成「等一个平台通道」。目录没就绪 ⇒ 直接当未命中。
  Future<String?> readHtml(String key) async {
    final file = _readyFileOf(key);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// 原子写一串原文（写盘本身不改状态：状态由下载队列在拿到结果后自己记）。
  Future<void> writeHtml(String key, String html) async {
    await _ensure();
    final file = await fileOf(key);
    if (file == null) return;
    try {
      await _atomicWrite(file, html);
    } catch (_) {
      return;
    }
    // 顺手把实际字节数记进索引（容量统计只认索引，不扫目录）
    final entry = _units[key];
    if (entry != null) {
      try {
        entry.bytes = await file.length();
      } catch (_) {
        // 量不到就保留原值，不给假数字
      }
      await _saveIndex();
    }
    notifyListeners();
  }

  /* ------------------------------ 漫画页（第二期） ----------------------------- */

  /// 漫画某一页的本机图文件；**同步**，渲染侧每帧都要用。
  ///
  /// 与 [_readyFileOf] 同口径：**不 await 原生通道**，目录没就绪就当没有。
  /// 顺手 stat 一次 —— `Image.file` 拿到不存在的路径会直接报错，一次
  /// `existsSync` 比「解码失败再兜底」便宜得多。
  File? peekImageFile(String chaptId, int page) {
    final dir = _readyDir;
    if (dir == null) return null;
    final rel = relativeImagePathOf(chaptId, page);
    if (rel == null) return null;
    final file = File('${dir.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}');
    try {
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 写侧用：会先把目录解析好（不检查文件是否存在，写盘自己会建目录）。
  Future<File?> imageFileOf(String chaptId, int page) async {
    final dir = await _cacheDir();
    if (dir == null) return null;
    final rel = relativeImagePathOf(chaptId, page);
    if (rel == null) return null;
    return File('${dir.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}');
  }

  /// 漫画某一页原文（`manga:<chaptId>:<page>` 的便利方法，免得各处自己拼 key）。
  Future<String?> readPageHtml(String chaptId, int page) =>
      readHtml('manga:$chaptId:$page');

  /// 落一页图的字节。
  ///
  /// **不查索引、不改状态、不通知**：一话要写 38 页，状态与字节总数由下载队列
  /// 在整话完成后统一 `markDone(bytes:)` 落账（第二期 2B，2026-11-24）。
  Future<void> writeImage(String chaptId, int page, List<int> bytes) async {
    final file = await imageFileOf(chaptId, page);
    if (file == null) return;
    try {
      await _atomicWriteBytes(file, bytes);
    } catch (_) {
      // 写失败静默：队列会按「这一页失败」处理，不必在这里抛
    }
  }

  /* ------------------------- 论坛图（第三期） ------------------------- */

  /// `ym_cache/forum_img/<hash>.img` 的相对路径。
  ///
  /// 为什么按 **URL 的哈希**而不是按帖子 / 页码分层：论坛图的取用方
  /// （`YmForumImage` / 图片查看器 / 首页头像位）手上只有 URL，拿不到 tid；
  /// 路径必须能从 URL 单向推出来，否则渲染侧每帧都要去查一次索引。
  ///
  /// 扩展名统一 `.img`：站点给的附件可能是 .jpg / .png / .webp，解码靠字节嗅探，
  /// 不在文件名上假装知道格式。
  static String? relativeForumImagePathOf(String url) {
    if (url.isEmpty) return null;
    return 'forum_img/${_urlHash(url)}.img';
  }

  /// FNV-1a 64。**不用 `String.hashCode`**：那个只保证同一进程内一致，
  /// 换个运行环境就变，落盘路径要跨进程稳定。
  static String _urlHash(String url) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(url)) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  /// 论坛图的本机文件；**同步**（渲染侧每帧要用，同 [peekImageFile]）。
  File? peekForumImageFile(String url) {
    final rel = relativeForumImagePathOf(url);
    if (rel == null) return null;
    final file = _fileAt(rel);
    if (file == null) return null;
    try {
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 落一张论坛图的字节。**不查索引、不改状态、不通知**：图的字节归到
  /// 「引用它的那一页」的 `bytes` 里，由下载队列整页完成后统一落账。
  Future<void> writeForumImage(String url, List<int> bytes) async {
    final rel = relativeForumImagePathOf(url);
    if (rel == null) return;
    await _cacheDir();
    final file = _fileAt(rel);
    if (file == null) return;
    try {
      await _atomicWriteBytes(file, bytes);
    } catch (_) {
      // 和图 / cover 同一口径：抓不到就继续显示占位，不让整页失败
    }
  }

  /// 一个帖子的图片清单 `forum/<tid>/images.json`：删帖时按它清图，不留孤儿。  ///
  /// 放在帖子目录里而不是索引里：图是「帖子级附属件」，一页 HTML 一条 unit，
  /// 在索引里再记一遍图会改 `index.json` 的结构。
  static String? relativeForumImagesPathOf(String tid) {
    final id = _safeName(tid);
    if (id.isEmpty) return null;
    return 'forum/$id/images.json';
  }

  /// 读清单（没有 / 坏档一律空表，不抛）。
  Future<List<String>> readForumImageRefs(String tid) async {
    final rel = relativeForumImagesPathOf(tid);
    if (rel == null) return const <String>[];
    final file = _fileAt(rel);
    if (file == null) return const <String>[];
    try {
      if (!file.existsSync()) return const <String>[];
      final json = jsonDecode(file.readAsStringSync());
      if (json is! List<Object?>) return const <String>[];
      return <String>[for (final e in json) if (e is String && e.isNotEmpty) e];
    } catch (_) {
      return const <String>[];
    }
  }

  /// 往清单里并入一批 URL（去重、原子写）。
  Future<void> addForumImageRefs(String tid, Iterable<String> urls) async {
    final rel = relativeForumImagesPathOf(tid);
    if (rel == null) return;
    await _cacheDir();
    final file = _fileAt(rel);
    if (file == null) return;
    final merged = <String>{...await readForumImageRefs(tid)};
    final before = merged.length;
    merged.addAll(urls.where((u) => u.isNotEmpty));
    if (merged.length == before) return;
    try {
      await _atomicWrite(file, jsonEncode(merged.toList()));
    } catch (_) {
      // 清单写不进去只影响「删帖时能不能顺手删图」，不影响这一页的可用性
    }
  }

  /// 帖子的内容指纹与「上次成功检查时间」`forum/<tid>/fp.json`。
  ///
  /// 结构：`{"1": {"fp": "a1b2…", "at": 1735660800, "last": "same"}}`。
  ///
  /// 放在帖子目录里（与页面原文同级）：删帖时目录整个删掉，指纹自然跟着走。
  static String? relativeForumFpPathOf(String tid) {
    final id = _safeName(tid);
    if (id.isEmpty) return null;
    return 'forum/$id/fp.json';
  }

  /// 读全部页的指纹记录（没有 / 坏档一律空表，不抛）。
  Future<Map<int, YmForumPageFp>> readForumFingerprints(String tid) async {
    final rel = relativeForumFpPathOf(tid);
    if (rel == null) return const <int, YmForumPageFp>{};
    final file = _fileAt(rel);
    if (file == null) return const <int, YmForumPageFp>{};
    try {
      if (!file.existsSync()) return const <int, YmForumPageFp>{};
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, Object?>) return const <int, YmForumPageFp>{};
      final out = <int, YmForumPageFp>{};
      json.forEach((key, value) {
        final page = int.tryParse(key);
        if (page == null || value is! Map<String, Object?>) return;
        final fp = (value['fp'] as String?) ?? '';
        if (fp.isEmpty) return;
        out[page] = YmForumPageFp(
          fp: fp,
          at: (value['at'] as num?)?.toInt() ?? 0,
          last: (value['last'] as String?) ?? '',
        );
      });
      return out;
    } catch (_) {
      return const <int, YmForumPageFp>{};
    }
  }

  /// 写一页的指纹（下载 / 刷新之后调）。`at` 保持不变：换内容不是"核对过"。
  /// `last` 一并清空 —— 内容已经是新的了，上一轮「发现变化」的提示到此为止。
  Future<void> putForumFingerprint(
    String tid,
    int page,
    String fp, {
    int? at,
  }) async {
    if (page <= 0 || fp.isEmpty) return;
    final rel = relativeForumFpPathOf(tid);
    if (rel == null) return;
    await _cacheDir();
    final file = _fileAt(rel);
    if (file == null) return;
    final all = Map<int, YmForumPageFp>.from(
      await readForumFingerprints(tid),
    );
    final old = all[page];
    all[page] = YmForumPageFp(fp: fp, at: at ?? old?.at ?? 0);
    await _writeForumFps(file, all);
  }

  /// 记一次**核对结果**（检查更新用）：只写 [at] 与 [last]，**不动 fp**。
  ///
  /// [at] 只在核对成功时推进（`failed` 不推进）——「上次检查」的口径是
  /// "成功核对完那一刻"，失败不该算。
  Future<void> markForumChecked(
    String tid,
    int page, {
    required String last,
    int? at,
  }) async {
    if (page <= 0) return;
    final rel = relativeForumFpPathOf(tid);
    if (rel == null) return;
    await _cacheDir();
    final file = _fileAt(rel);
    if (file == null) return;
    final all = Map<int, YmForumPageFp>.from(
      await readForumFingerprints(tid),
    );
    final old = all[page];
    all[page] = YmForumPageFp(
      fp: old?.fp ?? '',
      at: last == YmForumPageFp.failed ? (old?.at ?? 0) : (at ?? 0),
      last: last,
    );
    await _writeForumFps(file, all);
  }

  Future<void> _writeForumFps(File file, Map<int, YmForumPageFp> all) async {
    try {
      await _atomicWrite(
        file,
        jsonEncode(<String, Object?>{
          for (final e in all.entries)
            '${e.key}': <String, Object?>{
              'fp': e.value.fp,
              'at': e.value.at,
              'last': e.value.last,
            },
        }),
      );
    } catch (_) {
      // 指纹写不进去只影响「下次检查更准」，不影响页面可用
    }
  }

  /// 帖子的落盘目录（删帖时连目录与图一起删）。
  static Future<Directory?> _forumDirOf(String tid) async {
    final dir = await _cacheDir();
    if (dir == null) return null;
    final id = _safeName(tid);
    if (id.isEmpty) return null;
    return Directory(
      '${dir.path}${Platform.pathSeparator}forum${Platform.pathSeparator}$id',
    );
  }

  /// 删一个帖子的全部落盘件：`forum/<tid>/` 整个目录（各页原文 + 图片清单）
  /// + 清单里记着的那些图。
  ///
  /// 先读清单再删目录：目录一删清单就没了，图会变成找不到主人的孤儿。
  /// 图按 URL 哈希存放，理论上可能被另一个帖子引用同一张（同一附件链）——
  /// 那种情况删帖会把图也带走，另一方下次打开回落网络，不伪造内容。
  Future<void> _deleteForumParent(String tid) async {
    final refs = await readForumImageRefs(tid);
    final dir = await _forumDirOf(tid);
    if (dir != null) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // 同 unit：删不掉就让索引先走
      }
    }
    for (final url in refs) {
      await _deleteRelativeQuietly(relativeForumImagePathOf(url));
    }
  }

  /// 某一话的落盘目录（删 unit 时要连整个目录一起删）。
  static Future<Directory?> _chapterDirOf(String chaptId) async {
    final dir = await _cacheDir();
    if (dir == null) return null;
    final id = _safeName(chaptId);
    if (id.isEmpty) return null;
    return Directory(
      '${dir.path}${Platform.pathSeparator}manga${Platform.pathSeparator}$id',
    );
  }

  /* ------------------------- 封面与作品元信息（第三期） ------------------------- */

  /// `ym_cache/covers/<source>-<parent>.jpg` 的相对路径（每本一份）。
  ///
  /// 按 `source + parent` 推而不是存索引：封面是「这本作品的附属件」，
  /// 字节永久可用（签名的 URL 会过期，见第一期 §五），文件名不需要再进索引。
  static String? relativeCoverPathOf(String source, String parent) {
    final s = _safeName(source);
    final p = _safeName(parent);
    if (s.isEmpty || p.isEmpty) return null;
    return 'covers/$s-$p.jpg';
  }

  /// `ym_cache/meta/<source>-<parent>.json` 的相对路径（作品级小文件）。
  ///
  /// 独立小文件、**不改 `index.json` 的结构**：改结构要动版本与全部读侧，
  /// 而这里只有「离线合成 detail」一个读者（第三期任务 A / B）。
  static String? relativeMetaPathOf(String source, String parent) {
    final s = _safeName(source);
    final p = _safeName(parent);
    if (s.isEmpty || p.isEmpty) return null;
    return 'meta/$s-$p.json';
  }

  File? _fileAt(String rel) {
    final dir = _readyDir;
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}');
  }

  /// 作品封面的本机图文件；**同步**，与 [peekImageFile] 同口径
  /// （渲染侧每帧要用，不能 await 平台通道）。没存过 / 目录没就绪 = null。
  File? peekCoverFile(String source, String parent) {
    final rel = relativeCoverPathOf(source, parent);
    if (rel == null) return null;
    final file = _fileAt(rel);
    if (file == null) return null;
    try {
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 写侧：会先把目录解析好（写盘自己会建目录）。
  Future<File?> coverFileOf(String source, String parent) async {
    await _cacheDir();
    final rel = relativeCoverPathOf(source, parent);
    if (rel == null) return null;
    return _fileAt(rel);
  }

  /// 落一本作品的封面字节（走既有的字节原子写）。
  ///
  /// **不查索引、不改状态**：封面是「顺手抓一次」的附属件，抓不到就继续
  /// 显示占位（第三期任务 B），不因为没封面就让下载失败。
  Future<void> writeCover(
    String source,
    String parent,
    List<int> bytes,
  ) async {
    final file = await coverFileOf(source, parent);
    if (file == null) return;
    try {
      await _atomicWriteBytes(file, bytes);
    } catch (_) {
      return;
    }
    notifyListeners();
  }

  Future<File?> metaFileOf(String source, String parent) async {
    await _cacheDir();
    final rel = relativeMetaPathOf(source, parent);
    if (rel == null) return null;
    return _fileAt(rel);
  }

  /// 存作品级元信息（`author` / `cat` / `form` / `cover` 四个字符串）。
  ///
  /// 离线合成 detail 靠它补 `author` / `cat` 与漫画 `form`：`form` 丢了会让
  /// 条漫作品按分页打开（第三期任务 A 的已知坑）。
  Future<void> writeMeta(
    String source,
    String parent,
    Map<String, String> fields,
  ) async {
    final file = await metaFileOf(source, parent);
    if (file == null) return;
    try {
      await _atomicWrite(file, jsonEncode(fields));
    } catch (_) {
      // 写不进去只影响「断网时详情补不补得全」，不阻塞下载
    }
  }

  /// 读作品级元信息；没有 / 坏档 / 目录没就绪一律 null（调用方给空值）。
  /// 读路径同样同步读（见 [readDetailHtml] 的理由）。
  Future<Map<String, String>?> readMeta(String source, String parent) async {
    final rel = relativeMetaPathOf(source, parent);
    if (rel == null) return null;
    final file = _fileAt(rel);
    if (file == null) return null;
    try {
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      return <String, String>{
        for (final e in json.entries) e.key: (e.value ?? '').toString(),
      };
    } catch (_) {
      return null;
    }
  }

  /// 删一个相对路径的文件（封面 / meta 这类附属件用），删不掉静默。
  Future<void> _deleteRelativeQuietly(String? rel) async {
    if (rel == null) return;
    final file = _fileAt(rel);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 同 unit：删不掉就让索引先走
    }
  }

  /// `ym_cache/detail/<source>-<parent>.html`：作品详情页**原文**的本地副本
  /// （第四期任务 D，2026-11-24）。
  ///
  /// 为什么存原文而不是存模型：读侧重新走 parser（纯函数、毫秒级），站点加字段
  /// 也不会让旧副本读不出来 —— 与章节缓存同一套口径。
  /// 写入时机只有两个：**下载这本时存一次** + **有网打开这本详情页时刷新**。
  static String? relativeDetailPathOf(String source, String parent) {
    final s = _safeName(source);
    final p = _safeName(parent);
    if (s.isEmpty || p.isEmpty) return null;
    return 'detail/$s-$p.html';
  }

  Future<File?> detailFileOf(String source, String parent) async {
    await _cacheDir();
    final rel = relativeDetailPathOf(source, parent);
    if (rel == null) return null;
    return _fileAt(rel);
  }

  /// 存详情页原文（原子写、不通知：详情页自己不靠它刷界面）。
  Future<void> writeDetailHtml(
    String source,
    String parent,
    String html,
  ) async {
    final file = await detailFileOf(source, parent);
    if (file == null) return;
    try {
      await _atomicWrite(file, html);
    } catch (_) {
      // 写不进去只影响「断网时详情页还能不能开」，不阻塞当前操作
    }
  }

  /// 读详情页原文；没有 / 坏档 / 目录没就绪一律 null（调用方当没有副本）。
  ///
  /// ⚠ 这里是**同步读**（一份几十 KB 的 HTML，毫秒级），理由两条：
  /// * 读路径不能 await `YmNative.filesDir()`（同 [_readyFileOf]：通道一回不来
  ///   widget 测试就卡在 loading）；
  /// * 也不能把「有没有本机副本」拖成真实 I/O —— 详情页首帧要立刻画出来。
  Future<String?> readDetailHtml(String source, String parent) async {
    final rel = relativeDetailPathOf(source, parent);
    if (rel == null) return null;
    final file = _fileAt(rel);
    if (file == null) return null;
    try {
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// 这本有没有本地详情副本（同步，队列侧判断「要不要抓一次」用）。
  bool hasDetailHtml(String source, String parent) {
    final rel = relativeDetailPathOf(source, parent);
    if (rel == null) return false;
    final file = _fileAt(rel);
    if (file == null) return false;
    try {
      return file.existsSync();
    } catch (_) {
      return false;
    }
  }

  /* -------------------------------- 索引 -------------------------------- */

  /// 同步读内存索引（界面逐帧要用，不能 await）。未 load 时为空。
  YmCacheEntry? peek(String key) => _units[key];

  /// 同步拿全部（未 load 时为空）。
  List<YmCacheEntry> peekAll() => _units.values.toList();

  List<YmCacheEntry> _ofParent(String source, String parent) => _units.values
      .where((e) => e.source == source && e.parent == parent)
      .toList()
    ..sort((a, b) => a.order != b.order ? a.order - b.order : a.key.compareTo(b.key));

  Future<YmCacheEntry?> entryOf(String key) async {
    await _ensure();
    return _units[key];
  }

  Future<List<YmCacheEntry>> entriesOfParent(
    String source,
    String parentId,
  ) async {
    await _ensure();
    return _ofParent(source, parentId);
  }

  /// 同步版的 [entriesOfParent]（详情页每帧都要按章节查，不能 await）。
  List<YmCacheEntry> peekOfParent(String source, String parentId) =>
      _ofParent(source, parentId);

  /// 索引写入口：入队 / 转 running / 标失败都走它（名字叫 upsert 是因为
  /// 队列可能先写好元信息、下载完成后再回来改状态）。
  Future<void> upsert(YmCacheEntry entry) async {
    await _ensure();
    _units[entry.key] = entry;
    await _saveIndex();
    notifyListeners();
  }

  Future<void> markState(String key, YmCacheState state) async {
    await _ensure();
    final entry = _units[key];
    if (entry == null || entry.state == state) return;
    entry.state = state;
    await _saveIndex();
    notifyListeners();
  }

  /// 下载完成落账：记字节数 + 完成时间 + done。
  ///
  /// **不再做容量淘汰**（2026-11-24 用户拍板，第十九期）：离线内容是用户主动下的
  /// 东西，程序不替他删。这里只写字节数与时间，写完就返回。
  ///
  /// [at] 只给测试钉「谁更老」用（unix 秒）；正常调用不传，取当前时间。
  Future<void> markDone(String key, {int bytes = 0, int? at}) async {
    await _ensure();
    final entry = _units[key];
    if (entry == null) return;
    entry
      ..state = YmCacheState.done
      ..bytes = bytes < 0 ? 0 : bytes
      ..at = at ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _saveIndex();
    notifyListeners();
  }

  /// 已落账的 unit 占多少字节（给队列 / 界面读实际大小用）。
  Future<int> bytesOf(String key) async {
    final file = await fileOf(key);
    if (file == null) return 0;
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  /* -------------------------------- 容量 -------------------------------- */

  /// 只统计 [YmCacheState.done] 的 unit（读索引，不扫目录 —— §2.6）。
  Future<int> totalBytes() async {
    await _ensure();
    var total = 0;
    for (final e in _units.values) {
      if (e.state.isDone) total += e.bytes;
    }
    return total;
  }

  /// 同步版总占用（「我的」页 / 离线内容页每帧要显示）。
  int get usedBytes {
    var total = 0;
    for (final e in _units.values) {
      if (e.state.isDone) total += e.bytes;
    }
    return total;
  }

  /* -------------------------------- 删除 -------------------------------- */

  Future<void> _deleteFileQuietly(String key) async {
    final parts = key.split(':');
    // 漫画 unit 没有单文件：一话在 `manga/<chaptId>/` 里（38 页 HTML + 38 张图），
    // 删 unit 要连目录一起删，否则索引说「没缓存」、渲染侧还能读到残留的图。
    if (parts.length == 2 && parts[0] == 'manga') {
      final dir = await _chapterDirOf(parts[1]);
      if (dir == null) return;
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // 同下：删不掉就让索引先走，下次启动再算
      }
      return;
    }
    final file = await fileOf(key);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 文件被占用（Android 上极少数情况）：索引先移掉，下次启动再算
    }
  }

  /// 删一个 unit：文件 + 索引（§任务1 验收）。
  Future<void> removeUnit(String key) async {
    await _ensure();
    await _deleteFileQuietly(key);
    if (_units.remove(key) != null) {
      await _saveIndex();
      notifyListeners();
    }
  }

  /// 删一整个作品的全部 offline unit（离线内容页的批量删 / 弹层里的「删除离线内容」）。
  ///
  /// 封面与作品元信息是这本的附属件（第三期任务 B）：**跟着一起删**，
  /// 否则列表回空态了、磁盘上还留着 `covers/`、`meta/` 的孤儿文件。
  Future<void> removeParent(String source, String parentId) async {
    await _ensure();
    final keys = _ofParent(source, parentId).map((e) => e.key).toList();
    for (final key in keys) {
      await _deleteFileQuietly(key);
      _units.remove(key);
    }
    if (keys.isNotEmpty) {
      await _saveIndex();
      notifyListeners();
    }
    // 论坛：各页原文与正文图都在 `forum/<tid>/` 与 `forum_img/` 下，
    // 按帖子整体清（图是帖子级附属件，不是某一页的）
    if (source == 'forum') {
      await _deleteForumParent(parentId);
    }
    // 附属件在「列表回空态」之后才删：它们不参与列表状态，
    // 别为了多删几个文件把界面拖住（也免得点完删除还得等两拍 I/O）。
    await _deleteRelativeQuietly(relativeCoverPathOf(source, parentId));
    await _deleteRelativeQuietly(relativeMetaPathOf(source, parentId));
    // 详情页副本也是这本的附属件：离线内容删了，断网就没必要还留着一份详情
    await _deleteRelativeQuietly(relativeDetailPathOf(source, parentId));
  }

  /// 清空全部（第 4 期的「一键清空」会用它，本期先备着，界面没有入口）。
  ///
  /// 封面 / 元信息同样不留下孤儿（与 [removeParent] 同一口径）。
  Future<void> clearAll() async {
    await _ensure();
    final entries = _units.values.toList();
    final parents = <(String, String)>{
      for (final e in entries) (e.source, e.parent),
    };
    _units.clear();
    for (final e in entries) {
      await _deleteFileQuietly(e.key);
    }
    await _saveIndex();
    notifyListeners();
    // 附属件放在状态更新之后删（与 [removeParent] 同一口径）
    for (final (source, parent) in parents) {
      if (source == 'forum') await _deleteForumParent(parent);
      await _deleteRelativeQuietly(relativeCoverPathOf(source, parent));
      await _deleteRelativeQuietly(relativeMetaPathOf(source, parent));
      await _deleteRelativeQuietly(relativeDetailPathOf(source, parent));
    }
  }

  /* -------------------------------- 测试 -------------------------------- */

  /// 仅供测试：指定缓存目录并复位内存态（`dir` 传 null 模拟「通道缺失」降级）。
  @visibleForTesting
  static void resetForTest({Directory? dir}) {
    _loading = null;
    _loaded = false;
    _testDir = dir;
    _resolvedDir = null;
    _units.clear();
  }

  /// 仅供测试：跳过懒载入直接读盘。
  @visibleForTesting
  static Future<void> loadNow() async {
    _loaded = false;
    _loading = null;
    await load();
  }
}
