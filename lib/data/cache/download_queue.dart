import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api.dart';
import '../forum/forum_fingerprint.dart' show forumPageFingerprint;
import '../forum/forum_api.dart'
    show fetchForumImageBytes, fetchForumThreadHtml;
import '../forum/forum_parser.dart' show parseThreadPage;
import '../http.dart';
import '../models.dart';
import '../parser.dart';
import 'image_bytes.dart';
import 'download_foreground.dart';
import 'ym_cache_store.dart';

/// 一条下载任务（= 一个 cache unit）。
class YmDownloadTask {
  YmDownloadTask({
    required this.key,
    required this.source,
    required this.parent,
    required this.parentTitle,
    required this.title,
    required this.chaptId,
    this.order = 0,
    this.total = 0,
    this.state = YmCacheState.queued,
    this.error = '',
  });

  final String key;
  final String source;
  final String parent;
  final String parentTitle;
  final String title;

  /// 章节 id（小说 = `chaptId`；第 2 期漫画也用它，页码另记）。
  final String chaptId;
  final int order;
  final int total;

  YmCacheState state;

  /// 失败原因（人话，直接给界面显示）。
  String error;

  /// 漫画这一话已经写到第几页（1 基，0 = 一页都没写）。
  ///
  /// **只在内存里**：不写进 `queue.json`（重启一律 paused，页级进度跟着作废；
  /// 断点续传第四期再说）。弹层靠它显示「第 3 话 · 12/38 页」。
  int pagesDone = 0;

  /// 这一话一共几页（第 1 页原文解析出来才知道，0 = 还不知道）。
  ///
  /// 同样只在内存里：索引里的 `pages` 要整话 done 才落账，下载过程中界面
  /// 只能靠它出「12/38 页」，不能编分母（§七.3）。
  int pagesTotal = 0;

  bool get isActive => state.isPending;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'source': source,
    'parent': parent,
    'parentTitle': parentTitle,
    'title': title,
    'chaptId': chaptId,
    'order': order,
    'total': total,
    'state': state.name,
  };

  static YmDownloadTask fromJson(Map<String, Object?> json) => YmDownloadTask(
    key: (json['key'] as String?) ?? '',
    source: (json['source'] as String?) ?? '',
    parent: (json['parent'] as String?) ?? '',
    parentTitle: (json['parentTitle'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    chaptId: (json['chaptId'] as String?) ?? '',
    order: (json['order'] as num?)?.toInt() ?? 0,
    total: (json['total'] as num?)?.toInt() ?? 0,
    state: YmCacheState.parse(json['state']),
  );
}

/// 串行下载队列（§任务 3）。
///
/// 口径（2026-11-23 拍板）：
/// * **串行**，一章一个请求，走 `YmHttp` 的 `normal` lane 默认节流（650ms 间隔），
///   **不另开并发**、不开后台服务、不发通知；
/// * 失败**自动重试一次**（`fetchChapterHtml` 自身不重试，重试只在这里做，免得叠成 4 次）；
/// * 一章失败**不阻塞后续章**；
/// * [cancelAll] 立刻停：当前请求不打断，结果丢弃，剩下的标 paused；
/// * 快照写 `ym_cache/queue.json`，重启读出来**全部标 paused、不自动续跑**
///   （没有前台服务，自动续跑会跟用户抢网）。
class YmDownloadQueue extends ChangeNotifier {
  YmDownloadQueue._();

  static final YmDownloadQueue instance = YmDownloadQueue._();

  static const String queueFileName = 'queue.json';

  static const int _queueVersion = 1;

  final List<YmDownloadTask> tasks = <YmDownloadTask>[];

  static bool _loaded = false;

  bool _pumping = false;

  /// 用户点了停止：当前请求落地后不再发下一个。
  bool _stop = false;

  /// 下载中任务的临时标记：界面用它画进度环（小说一章没有页级进度，只有
  /// 「在跑 / 不在跑」，所以这里只表达状态，不填百分比 —— 不编数字）。
  int get activeCount => tasks.where((t) => t.isActive).length;

  bool get busy => activeCount > 0;

  YmDownloadTask? get current {
    for (final t in tasks) {
      if (t.state == YmCacheState.running) return t;
    }
    return null;
  }

  List<YmDownloadTask> tasksOf(String source, String parentId) =>
      tasks.where((t) => t.source == source && t.parent == parentId).toList();

  /// 重启读出后全部标 paused（§任务 3）。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final inst = instance;
    inst.tasks.clear();
    // 队列要和索引对账（done 的不进队列），所以先保证索引读过
    await YmCache.load();
    try {
      final file = await YmCache.fileNamed(queueFileName);
      if (file == null || !await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return;
      final list = json['tasks'];
      if (list is! List<Object?>) return;
      for (final item in list) {
        if (item is! Map<String, Object?>) continue;
        final task = YmDownloadTask.fromJson(item);
        if (task.key.isEmpty) continue;
        // 已经落账的（索引里 done）不进队列：真相在索引，队列只管没跑完的
        if (YmCache.instance.peek(task.key)?.state.isDone ?? false) continue;
        // 不自动续跑：重启后一律 paused，等用户再点
        task.state = YmCacheState.paused;
        inst.tasks.add(task);
        await YmCache.instance.markState(task.key, YmCacheState.paused);
      }
    } catch (_) {
      inst.tasks.clear();
    }
  }

  Future<void> _save() async {
    try {
      final file = await YmCache.fileNamed(queueFileName);
      if (file == null) return;
      final payload = <String, Object?>{
        'version': _queueVersion,
        // 只留还没跑完的：done 的真相在 index.json，队列快照不重复记一遍
        'tasks': tasks
            .where((t) => t.state != YmCacheState.done)
            .map((t) => t.toJson())
            .toList(),
      };
      // 复用缓存层的原子写（`.tmp` + rename）：队列快照同样不能被写坏
      await YmCache.atomicJsonWrite(file, jsonEncode(payload));
    } catch (_) {
      // 快照写失败只影响「重启后还看不看得到队列」，不阻塞下载
    }
  }

  /* ------------------------------- 入队 ------------------------------- */

  /// 小说章节入队。**单章下载就是传只含一章的列表**，不另开方法（§任务 3）。
  ///
  /// 已经 done 的章、已经在队列里的章直接跳过：重复点同一章不会排两遍。
  Future<void> enqueueNovel(
    YmNovelDetail detail,
    List<YmChapterRef> chapters,
  ) async {
    await YmCache.load();
    await load();
    _stop = false;

    final total = detail.chapters.length;
    var changed = false;
    for (final ch in chapters) {
      final key = 'novel:${ch.id}';
      if (YmCache.instance.peek(key)?.state.isDone ?? false) continue;
      if (tasks.any((t) => t.key == key && t.isActive)) continue;
      final index = detail.chapters.indexWhere((c) => c.id == ch.id);
      final task = YmDownloadTask(
        key: key,
        source: 'novel',
        parent: detail.id,
        parentTitle: detail.title,
        title: ch.title,
        chaptId: ch.id,
        order: index < 0 ? 0 : index + 1,
        total: total,
      );
      // 之前失败 / 暂停过的：复用原条，状态回到 queued
      final old = tasks.where((t) => t.key == key).firstOrNull;
      if (old != null) {
        old
          ..state = YmCacheState.queued
          ..error = '';
      } else {
        tasks.add(task);
      }
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: key,
          source: 'novel',
          parent: detail.id,
          parentTitle: detail.title,
          title: ch.title,
          total: total,
          order: index < 0 ? 0 : index + 1,
          state: YmCacheState.queued,
        ),
      );
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    await _save();
    // 封面与作品元信息：**只有下载这一刻可靠地有网**（第三期任务 B）
    unawaited(
      _ensureParentAssets(
        source: 'novel',
        parent: detail.id,
        coverUrl: detail.cover,
        meta: <String, String>{
          'author': detail.author,
          'cat': detail.cat,
          'form': '',
        },
      ),
    );
    unawaited(_pump());
  }

  /// 漫画话入队（第二期 2C，结构与 [enqueueNovel] 同套）。
  ///
  /// 一条 unit = 一话（38 页 HTML + 38 张图），状态只有整话跑完才落 done；
  /// 单话下载同样是「传只含一话的列表」，不另开方法。
  Future<void> enqueueManga(
    YmMangaDetail detail,
    List<YmChapterRef> chapters,
  ) async {
    await YmCache.load();
    await load();
    _stop = false;

    final total = detail.chapters.length;
    var changed = false;
    for (final ch in chapters) {
      final key = 'manga:${ch.id}';
      if (YmCache.instance.peek(key)?.state.isDone ?? false) continue;
      if (tasks.any((t) => t.key == key && t.isActive)) continue;
      final index = detail.chapters.indexWhere((c) => c.id == ch.id);
      final order = index < 0 ? 0 : index + 1;
      // 之前失败 / 暂停过的：复用原条，状态回 queued、页进度清零
      final old = tasks.where((t) => t.key == key).firstOrNull;
      if (old != null) {
        old
          ..state = YmCacheState.queued
          ..error = ''
          ..pagesDone = 0;
      } else {
        tasks.add(
          YmDownloadTask(
            key: key,
            source: 'manga',
            parent: detail.id,
            parentTitle: detail.title,
            title: ch.title,
            chaptId: ch.id,
            order: order,
            total: total,
          ),
        );
      }
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: key,
          source: 'manga',
          parent: detail.id,
          parentTitle: detail.title,
          title: ch.title,
          total: total,
          order: order,
          state: YmCacheState.queued,
        ),
      );
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    await _save();
    // 封面与作品元信息（第三期任务 B）：与小说同一时机、同一套口径
    unawaited(
      _ensureParentAssets(
        source: 'manga',
        parent: detail.id,
        coverUrl: detail.cover,
        meta: <String, String>{
          'author': detail.author,
          'cat': detail.cat,
          // 条漫 / 分页的判断靠它，丢了条漫作品会按分页打开
          'form': detail.form,
        },
      ),
    );
    unawaited(_pump());
  }

  /// 帖子分页入队（缓存第三期，2026-11-24）。
  ///
  /// 一个 unit = **一页帖子**（原文 + 这一页里的正文图），与小说一章同粒度：
  /// 帖子页没有「整帖读完」的形态，翻到哪页就在哪页，按页存才对得上
  /// 「断网能读已下载的帖页」这条判据。
  ///
  /// [pages] 是 1 基页码集合；[totalPages] / [replies] 由调用方从帖页解析结果给，
  /// **不在这里重新抓**（调用方手上正好有）。
  /// [redo] = 「重下已存页」：已存过的页也重新排一遍（顶掉旧副本）。
  Future<void> enqueueForum({
    required String tid,
    required String title,
    required List<int> pages,
    int totalPages = 0,
    int replies = 0,
    bool redo = false,
  }) async {
    await YmCache.load();
    await load();
    _stop = false;

    var changed = false;
    for (final page in pages) {
      if (page <= 0) continue;
      final key = 'forum:$tid:$page';
      if (!redo && (YmCache.instance.peek(key)?.state.isDone ?? false)) continue;
      if (tasks.any((t) => t.key == key && t.isActive)) continue;
      final old = tasks.where((t) => t.key == key).firstOrNull;
      if (old != null) {
        old
          ..state = YmCacheState.queued
          ..error = '';
      } else {
        tasks.add(
          YmDownloadTask(
            key: key,
            source: 'forum',
            parent: tid,
            parentTitle: title,
            // 一页一个 unit：标题就是页码，离线内容子页直接照它排
            title: '第 $page 页',
            chaptId: '$page',
            order: page,
            total: totalPages,
          ),
        );
      }
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: key,
          source: 'forum',
          parent: tid,
          parentTitle: title,
          title: '第 $page 页',
          total: totalPages,
          order: page,
          state: YmCacheState.queued,
        ),
      );
      changed = true;
    }
    if (!changed) return;
    // 帖子级记录：`totalPages` / `replies` 是「检查更新」的比对基准
    // （不逐楼 diff、不轮询，见缓存第一期 §三之二）。存在 `meta/forum-<tid>.json`。
    await YmCache.instance.writeMeta('forum', tid, <String, String>{
      'title': title,
      'total': '$totalPages',
      'replies': '$replies',
      'savedAt': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    });
    notifyListeners();
    await _save();
    unawaited(_pump());
  }

  /// 把队列里失败 / 暂停的任务全部重排（弹层里「下载全部」的点法就是它 +
  /// [enqueueNovel] 的组合，这里只处理已经存在但没跑完的条）。
  Future<void> resumePending() async {
    await load();
    _stop = false;
    var changed = false;
    for (final t in tasks) {
      if (t.state == YmCacheState.failed || t.state == YmCacheState.paused) {
        t
          ..state = YmCacheState.queued
          ..error = ''
          ..pagesDone = 0;
        await YmCache.instance.markState(t.key, YmCacheState.queued);
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    await _save();
    unawaited(_pump());
  }

  /// 立刻停：当前请求不打断（结果丢弃），队列里剩下的标 paused，不再发新请求。
  Future<void> cancelAll() async {
    _stop = true;
    var changed = false;
    for (final t in tasks) {
      if (t.state == YmCacheState.queued) {
        t.state = YmCacheState.paused;
        await YmCache.instance.markState(t.key, YmCacheState.paused);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      await _save();
    }
  }

  /// 只停一本作品的任务（删这本的离线内容时用，别把别本排队的一起停掉）。
  Future<void> cancelOf(String source, String parentId) async {
    final mine = tasksOf(source, parentId);
    if (mine.isEmpty) return;
    if (mine.any((t) => t.state == YmCacheState.running)) _stop = true;
    var changed = false;
    for (final t in mine) {
      if (t.state == YmCacheState.queued || t.state == YmCacheState.running) {
        t.state = YmCacheState.paused;
        await YmCache.instance.markState(t.key, YmCacheState.paused);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      await _save();
    }
  }

  /* ---------------------------- 作品附属件（封面） ---------------------------- */

  /// 给这本作品顺手存三样附属件：**详情页副本** + **封面字节** + **作品级元信息**
  /// （第三期任务 B、第四期选项 D，2026-11-24）。
  ///
  /// 四条口径：
  /// * 详情副本取 api 层内存里的那份原文（[peekDetailHtml]），断网时详情页
  ///   与「继续阅读」靠它，**不为此另发一次请求**；
  /// * 抓图走现成的 [YmImageBytes.fetch]（同一条字节通道、同 UA 规则）；
  /// * 每本一份，路径按 `source + parent` 推（`ym_cache/covers/<source>-<parent>.jpg`）；
  /// * 抓失败**静默**、不影响下载：没有封面就继续显示首字占位，不编一张图；
  /// * 触发点必须在这里（下载那一刻才有网），不能等到「打开离线页」才抓 ——
  ///   断网时抓不到，等于永远没封面。
  ///
  /// 元信息落 `ym_cache/meta/<source>-<parent>.json`（独立小文件，不改 `index.json`
  /// 的结构）：任务 A 合成 detail 时靠它补 `author` / `cat` 与漫画 `form`。
  Future<void> _ensureParentAssets({
    required String source,
    required String parent,
    required String coverUrl,
    required Map<String, String> meta,
  }) async {
    final cache = YmCache.instance;
    // 详情页副本（第四期选项 D）：用户就是**从这本书的详情页**点的下载，
    // 那份原文还在 api 层的内存备忘里 —— 直接把它落到本地，**不再发第二次请求**。
    // 没有备忘（进程重启过 / 非详情页入口）就等下次有网打开详情页时刷新。
    if (!cache.hasDetailHtml(source, parent)) {
      final html = peekDetailHtml(source, parent);
      if (html != null) {
        await cache.writeDetailHtml(source, parent, html);
      }
    }
    if (cache.peekCoverFile(source, parent) == null && coverUrl.isNotEmpty) {
      try {
        final bytes = await YmImageBytes.fetch(coverUrl);
        await cache.writeCover(source, parent, bytes);
      } catch (_) {
        // 封面只是附属件：抓不到就保持占位
      }
    }
    await cache.writeMeta(source, parent, <String, String>{
      ...meta,
      'cover': cache.peekCoverFile(source, parent) == null ? '' : '1',
    });
  }

  /* ------------------------------- 执行 ------------------------------- */

  YmDownloadTask? _nextQueued() {
    for (final t in tasks) {
      if (t.state == YmCacheState.queued) return t;
    }
    return null;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        if (_stop) break;
        final task = _nextQueued();
        if (task == null) break;

        task
          ..state = YmCacheState.running
          ..pagesDone = 0
          ..pagesTotal = 0;
        await YmCache.instance.markState(task.key, YmCacheState.running);
        // 开跑第一个任务就起前台服务：之后切到别的应用 / 熄屏，下载也不会被系统掐断
        await YmDownloadForeground.start(_noticeOf(task));
        notifyListeners();

        // 按 source 分派（第二期 2C）：小说一章一个请求，漫画一话 38 页图
        final result = await _runOne(task);

        if (_stop || result.cancelled) {
          task.state = YmCacheState.paused;
          await YmCache.instance.markState(task.key, YmCacheState.paused);
        } else if (result.ok) {
          task
            ..state = YmCacheState.done
            ..error = '';
        } else {
          task
            ..state = YmCacheState.failed
            ..error = result.reason.isEmpty ? '下载失败，请稍后再试' : result.reason;
          await YmCache.instance.markState(task.key, YmCacheState.failed);
        }
        notifyListeners();
        await _save();
      }
    } finally {
      _pumping = false;
      // 停下来之后不把 _stop 留着：下一次入队要能重新跑
      _stop = false;
      // 队列跑空 / 被停：撤掉那条常驻通知，别让它留在通知栏里假装还在下
      await YmDownloadForeground.stop();
    }
  }

  /// 通知正文（抬头「正在离线保存」由原生侧固定，这里只给后面的内容）。
  ///
  /// 一话在跑就带页数，其余只给「作品 · 这一话 / 这一章」；不带百分比、
  /// 不写「还剩 x 分钟」：分母和速度都不稳，编出来的数字只会骗人。
  String _noticeOf(YmDownloadTask task) {
    final title = task.parentTitle.isEmpty ? task.title : task.parentTitle;
    final pages = task.pagesTotal > 0 ? ' · ${task.pagesDone}/${task.pagesTotal} 页' : '';
    final left = activeCount > 1 ? ' · 还有 ${activeCount - 1} 个在排队' : '';
    return '$title · ${task.title}$pages$left';
  }


  Future<_RunResult> _runOne(YmDownloadTask task) => switch (task.source) {
    'novel' => _downloadNovel(task),
    'manga' => _downloadManga(task),
    'forum' => _downloadForum(task),
    // 未知 source 明说，别静默当成小说去取正文
    _ => Future<_RunResult>.value(
      const _RunResult(reason: '这种内容还不能离线保存'),
    ),
  };

  /// 小说：整章一个请求，失败重试一次（[fetchChapterHtml] 自己不重试）。
  Future<_RunResult> _downloadNovel(YmDownloadTask task) async {
    var reason = '';
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_stop) return const _RunResult(cancelled: true);
      try {
        final html = await fetchChapterHtml(task.chaptId);
        if (_stop) {
          // 用户在请求途中点了停止：这一章的字节直接丢弃，不落盘
          return const _RunResult(cancelled: true);
        }
        await YmCache.instance.writeHtml(task.key, html);
        final bytes = await YmCache.instance.bytesOf(task.key);
        // 不设容量上限（2026-11-24 拍板），但写盘失败不能算成功：读回来是空的
        // 就判这一章失败，给一句人话，别让「下完了」点开是空白。
        if (bytes <= 0) {
          return const _RunResult(reason: '这一章没存下来，可能是手机存储空间不够');
        }
        await YmCache.instance.markDone(task.key, bytes: bytes);
        return const _RunResult(ok: true);
      } catch (e) {
        reason = e is YmHttpError ? e.message : '下载失败，请稍后再试';
        // 登录要求不是网络问题，重试也没用
        if (e is YmHttpError && e.isLoginRequired) break;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1400));
        }
      }
    }
    return _RunResult(reason: reason);
  }

  /// 取一页原文，**失败重试一次**。
  ///
  /// 为什么这里破例重试（2026-11-24 探针实测）：连下 38 页时站点偶发 502
  /// （38 页里 7 页 502，页图一律 200、没有任何 403 限流）。不重试的话
  /// 一次抖动就让整话失败、用户得重新点一遍；只重试页原文（1.4s 后一次），
  /// 页图仍不重试（大文件重下代价高，且失败基本是签名 / 网络硬错）。
  Future<String> _mangaPageHtml(String id, int page) async {
    try {
      return await fetchMangaPageHtml(id, page);
    } on YmHttpError catch (e) {
      // 登录失效 / 解析不出图：重试没意义
      if (e.isLoginRequired || e.code == 'PARSE') rethrow;
      if (_stop) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      return fetchMangaPageHtml(id, page);
    }
  }

  /// 漫画一话：逐页「页 HTML + 图字节」，整话跑完才落 done（第二期 2C）。
  ///
  /// 三条刻意的取舍（2026-11-23 拍板）：
  /// * **每写一页就 `notifyListeners`**：一话 38 页 ≈ 50 秒，攒到整话结束才通知
  ///   会让界面看起来像卡死；
  /// * **单页失败 ⇒ 整话 failed**，`error` 带页号；已经写下的半话文件**留着但不计入
  ///   容量**（只有 `done` 参与统计）—— 清理归第四期，本期不删，因为下次重下会
  ///   按页覆盖，先删反而多一次 IO；
  /// * **字节自己累加，不用 `bytesOf`**：`bytesOf` 量的是 `fileOf(key)` 那一个文件，
  ///   漫画 unit 按新布局根本没有单文件（量出来永远是 0）。
  Future<_RunResult> _downloadManga(YmDownloadTask task) async {
    final id = task.chaptId;
    const cancelled = _RunResult(cancelled: true);
    var bytes = 0;
    var page = 1;
    try {
      // 第 1 页的原文同时给出总页数，后面几页各取一次
      final firstHtml = await _mangaPageHtml(id, 1);
      if (_stop) return cancelled;
      final first = parseMangaChapter(firstHtml, 1).page;
      final totalPages = first.totalPages < 1 ? 1 : first.totalPages;
      task.pagesTotal = totalPages;

      for (page = 1; page <= totalPages; page++) {
        if (_stop) return cancelled;
        final html = page == 1 ? firstHtml : await _mangaPageHtml(id, page);
        if (_stop) return cancelled;
        // 第 1 页已经解析过，别重复解
        final sample = page == 1
            ? first
            : parseMangaChapter(html, page).page;
        if (sample.image.isEmpty) {
          throw YmHttpError('这一页没有图片，章节可能不存在', code: 'PARSE');
        }
        await YmCache.instance.writeHtml('manga:$id:$page', html);
        final data = await YmImageBytes.fetch(sample.image);
        if (_stop) {
          // 停止时这一页的图不落盘；已写下的前几页留着（本期不做断点续传）
          return cancelled;
        }
        await YmCache.instance.writeImage(id, page, data);
        // 不设容量上限（2026-11-24 拍板），但写盘失败不能算成功：图没落下去
        // （手机存储满了 / 目录写不了）就当这一页失败，别让整话标 done 而点开是空白。
        if (YmCache.instance.peekImageFile(id, page) == null) {
          throw const _DiskWriteError();
        }
        bytes += utf8.encode(html).length + data.length;
        task.pagesDone = page;
        // 通知栏那一行跟着页数走（节流在 YmDownloadForeground 里，逐页刷不心疼）
        unawaited(YmDownloadForeground.update(_noticeOf(task)));
        notifyListeners();
      }

      // ⚠ markDone 不认 pages：先拿索引里的那条（`peek` 给的就是同一实例）
      // 把页数改掉，再落账，`_saveIndex` 时会一起写下。
      final entry = YmCache.instance.peek(task.key);
      if (entry != null) entry.pages = totalPages;
      await YmCache.instance.markDone(task.key, bytes: bytes);
      return const _RunResult(ok: true);
    } on _DiskWriteError {
      return _RunResult(reason: '第 $page 页没存下来，可能是手机存储空间不够');
    } catch (e) {
      // 登录失效不是「第几页」的问题，原样给用户看
      if (e is YmHttpError && e.isLoginRequired) {
        return _RunResult(reason: e.message);
      }
      return _RunResult(reason: '第 $page 页下载失败，请稍后再试');
    }
  }

  /// 帖子一页：原文 + 这一页里的正文图（缓存第三期，2026-11-24）。
  ///
  /// 三条取舍：
  /// * **失败重试一次**（与小说同一档）：论坛偶发 502，一次抖动不该让整页作废；
  /// * **单张图抓不到不算整页失败**：正文是主体，图缺一张仍然可读，
  ///   而把整页判失败会让用户「明明能看字却说下载失败」；
  /// * **字节自己累加**（原文 + 图），因为一页没有单一文件可量。
  ///
  /// 图按 URL 哈希落 `forum_img/`，并记进 `forum/<tid>/images.json`，
  /// 删帖时按清单一起清（`YmCache.removeParent`）。
  Future<_RunResult> _downloadForum(YmDownloadTask task) async {
    final tid = task.parent;
    final page = int.tryParse(task.chaptId) ?? 0;
    if (page <= 0) return const _RunResult(reason: '页码不对，没法保存这一页');
    var reason = '';
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_stop) return const _RunResult(cancelled: true);
      try {
        final html = await fetchForumThreadHtml(tid, page: page);
        if (_stop) return const _RunResult(cancelled: true);
        final data = parseThreadPage(html, tid: tid, page: page);
        if (data.posts.isEmpty) {
          // 空帖 / 消息页 / 权限页：存下去也没东西可读，别占一份「已存」
          throw YmHttpError('这一页没有楼层，可能是权限或帖子已删', code: 'PARSE');
        }
        await YmCache.instance.writeHtml(task.key, html);
        // 记下这一页的内容指纹：之后「检查更新」靠它判断本机这份变没变
        await YmCache.instance.putForumFingerprint(
          tid,
          page,
          forumPageFingerprint(data),
        );
        var bytes = utf8.encode(html).length;

        final saved = <String>[];
        for (final url in <String>{
          for (final post in data.posts) ...post.images,
        }) {
          if (_stop) return const _RunResult(cancelled: true);
          try {
            final image = await fetchForumImageBytes(url);
            await YmCache.instance.writeForumImage(url, image);
            bytes += image.length;
            saved.add(url);
          } catch (_) {
            // 单张图失败静默：缺图的帖子仍然能读
          }
        }
        await YmCache.instance.addForumImageRefs(tid, saved);

        // 不设容量上限（2026-11-24 拍板），但写盘失败不能算成功：读回来是空的
        // 就判这一页失败，给一句人话，别让「存完了」点开是空白。
        if (await YmCache.instance.readHtml(task.key) == null) {
          return const _RunResult(reason: '这一页没存下来，可能是手机存储空间不够');
        }
        await YmCache.instance.markDone(task.key, bytes: bytes);
        return const _RunResult(ok: true);
      } catch (e) {
        reason = e is YmHttpError ? e.message : '下载失败，请稍后再试';
        if (e is YmHttpError && e.isLoginRequired) break;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1400));
        }
      }
    }
    return _RunResult(reason: reason);
  }

  /* -------------------------------- 测试 -------------------------------- */

  /// 仅供测试：清空内存态（`queue.json` 由 `YmCache.resetForTest` 一起换目录）。
  @visibleForTesting
  static void resetForTest() {
    _loaded = false;
    instance.tasks.clear();
    instance._pumping = false;
    instance._stop = false;
  }

  /// 仅供测试：等队列跑完（最多等 [timeout]）。
  @visibleForTesting
  Future<void> drain({Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (busy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

/// 一个任务跑完的结果：`_pump` 只按这三样决定任务状态（状态落账的地方集中一处）。
class _RunResult {
  const _RunResult({this.ok = false, this.cancelled = false, this.reason = ''});

  final bool ok;

  /// 用户在请求途中点了停止（字节丢弃、任务回 paused）。
  final bool cancelled;

  /// 失败原因（人话，直接显示）。
  final String reason;
}

/// 页图写盘后找不到文件：`writeImage` 是「静默吞错」的（它不知道写失败该怪谁），
/// 所以由队列写完当场验一次存在性，失败了就抛这个，让整话给一句真话
/// （「没存下来」）而不是假装成功（2026-11-24，去掉容量上限后的安全网）。
class _DiskWriteError implements Exception {
  const _DiskWriteError();
}

/// `lib/data/cache/` 下两个源文件都用到的小工具（避免 import 循环用的扩展）。
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
