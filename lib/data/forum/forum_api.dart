/// 论坛取数编排（页面层只从这里拿数据，不直接碰 [ForumHttp]）。
///
/// 阶段 0 只有板块页；首页 / 帖子 / 我的随各期补。
/// 所有路径都带 `mobile=2`（Discuz 手机模板的硬口径）。
library;

import 'dart:io' show HttpHeaders;
import 'dart:typed_data' show Uint8List;

import '../cache/image_bytes.dart';
import '../cache/ym_cache_store.dart' show YmCache, YmForumPageFp;
import '../http.dart' show YmHttpError;
import 'forum_auth.dart' show ForumSession;
import 'forum_fingerprint.dart';
import 'forum_http.dart';
import 'forum_models.dart';
import 'forum_parser.dart';
import 'forum_user.dart';

/// 站方消息兜底（2026-11-15 定调）：解析认不出任何已知内容（无板块/无楼层/无列表）
/// + 页面命中 Discuz showmessage 消息页形状 → 抛 SITE_MESSAGE、摘站点提示原文
/// 给人看（管理员写什么——维护/关闭/公告——都能兜住，不赌关键词、不做原因猜测）。
/// 服务器级宕机是连接失败/5xx，现有网络错误态已覆盖，不在这里做。
void _throwIfSiteMessage(String html, {required bool nothingRecognized}) {
  if (!nothingRecognized) return;
  final msg = forumSiteMessage(html);
  if (msg != null) throw YmHttpError(msg, code: 'SITE_MESSAGE');
}

/// 板块一页。游客可读的板块（如动漫区 fid=5）直接可用；
/// 游客不可读的板块站点会 302 跳登录 → `LOGIN_REQUIRED` 错误。
///
/// [extra] 是板块页的筛选参数（最新 / 热门 / 精华等，站点自己的取值），
/// 由页面层从真实锚点 URL 里解析出来传进，不在这里硬编码站点行为。
Future<ForumBoardData> fetchForumBoard(
  String fid, {
  int page = 1,
  String extra = '',
  String? referer,
}) async {
  final res = await ForumHttp.instance.request(
    '/forum.php?mod=forumdisplay&fid=$fid&page=$page&mobile=2$extra',
    referer: referer,
  );
  final data = parseBoardPage(res.body, fid: fid, page: page);
  _throwIfSiteMessage(res.body, nothingRecognized: data.threads.isEmpty);
  return data;
}

/// 论坛首页（公告 + 分区卡）。
Future<ForumHome> fetchForumHome() async {
  final res = await ForumHttp.instance.request('/forum.php?mobile=2');
  final home = parseForumHome(res.body);
  _throwIfSiteMessage(res.body, nothingRecognized: home.cats.isEmpty);
  return home;
}

/// PC UA：站方「热点推荐」只在电脑版模板里印（DIY 模块，手机模板没有）。
/// 常量与阅读侧 `kYmPcUa` 无关——论坛侧自成一套，不 import 阅读侧。
const String kForumPcUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

/// 站方「热点推荐」（2026-11-15 用户拍板：首页热区换真数据）。
/// PC 版论坛首页的 DIY 模块（管理员手选的全站热点，游客可读）——
/// 站点按 UA 出模板，所以要带 PC UA 抓电脑版首页、只解析这一个块。
/// 块被站方改名/清空/挪位时解析返回空，首页热区安静隐藏（不编、不报错）。
Future<List<ForumThreadSummary>> fetchForumHot() async {
  final res = await ForumHttp.instance.request(
    '/forum.php',
    headers: {HttpHeaders.userAgentHeader: kForumPcUa},
  );
  return parseForumHot(res.body);
}

/// 帖子一页（每页约 10~20 楼，站点分页口径）。
///
/// **读盘优先**（缓存第三期，2026-11-24）：这一页如果离线保存过（索引里
/// `forum:<tid>:<page>` 是 done），直接读本机原文重新走 parser —— 断网能读、
/// 联网也不多发请求（内容以保存那一刻为准，要看新的走「刷新 / 检查更新」）。
/// 没存过就正常联网；联网失败（断网 / 站点 5xx / WAF）时再回头找一次磁盘，
/// 有副本就照常显示，没有才把原始错误抛给页面。
///
/// [forceRefresh] = 帖子菜单的「刷新」：跳过读盘，强制走网络。
/// [updateCache] = 这一页**已经离线存过**时，把刚取到的原文覆盖回去
/// （刷新与下载并列成"写盘的第二类意图"：用户点了刷新，就是要这份新内容）。
/// 没存过的页不写 —— 随手刷一下不该平白多出一份离线副本。
Future<ForumThreadPage> fetchForumThread(
  String tid, {
  int page = 1,
  bool forceRefresh = false,
  bool updateCache = false,
}) async {
  if (!forceRefresh) {
    final cached = await readCachedForumThread(tid, page: page);
    if (cached != null) return cached;
  }
  try {
    final html = await fetchForumThreadHtml(tid, page: page);
    final data = parseThreadPage(html, tid: tid, page: page);
    _throwIfSiteMessage(html, nothingRecognized: data.posts.isEmpty);
    if (updateCache && data.posts.isNotEmpty) {
      await cacheRefreshedForumPage(tid, page, html, data);
    }
    return data;
  } catch (e) {
    if (forceRefresh) rethrow;
    final cached = await readCachedForumThread(tid, page: page);
    if (cached != null) return cached;
    rethrow;
  }
}

/// 把刚取到的这一页覆盖到离线副本上（只在**已存过**的页上生效）。
///
/// 覆盖的内容是原文 + 指纹；`at`（上次检查时间）保持不变 —— 刷新是"换内容"，
/// 不是"核对过"，两者不能混。
Future<void> cacheRefreshedForumPage(
  String tid,
  int page,
  String html,
  ForumThreadPage data,
) async {
  final cache = YmCache.instance;
  if (!cache.dirReady || !cache.indexLoaded) return;
  if (!(cache.peek('forum:$tid:$page')?.state.isDone ?? false)) return;
  await cache.writeHtml('forum:$tid:$page', html);
  await cache.putForumFingerprint(tid, page, forumPageFingerprint(data));
}

/// 静默探一次「这帖现在共几页」：只取第 1 页、只要页数，**不写盘、不解析给界面**。
///
/// 用在进帖子页时：当前页来自离线副本、`_totalPages` 是存下来那天的旧值，
/// 探测成功就能把「可下载名单」和"下一页还能不能翻"一起更新。
/// 失败由调用方吞掉（无事发生）。
Future<int> probeForumThreadTotal(String tid) async {
  final html = await fetchForumThreadHtml(tid, page: 1);
  final data = parseThreadPage(html, tid: tid, page: 1);
  return data.totalPages;
}

/* ------------------------------ 检查更新 ------------------------------ */

/// 一页的核对结论。
class ForumPageCheck {
  const ForumPageCheck({
    required this.page,
    required this.result,
    required this.checkedAt,
    this.error = '',
  });

  final int page;

  /// `YmForumPageFp.same` / `changed` / `failed` / `first`。
  final String result;

  /// 这一页上次成功核对的时间（失败时是原来那个，不变）。
  final int checkedAt;

  final String error;

  bool get changed => result == YmForumPageFp.changed;

  bool get failed => result == YmForumPageFp.failed;

  bool get firstTime => result == YmForumPageFp.first;
}

/// 一次「检查更新」的完整结论。
class ForumCheckReport {
  const ForumCheckReport({
    required this.totalPages,
    required this.storedTotal,
    required this.pages,
  });

  /// 站点上现在共几页（0 = 没拿到）。
  final int totalPages;

  /// 上次保存时记下的总页数。
  final int storedTotal;

  final List<ForumPageCheck> pages;

  /// 新增页的页码（上次保存的末页之后）。
  List<int> get newPages {
    if (totalPages <= storedTotal) return const <int>[];
    return <int>[for (var p = storedTotal + 1; p <= totalPages; p++) p];
  }

  /// 内容有变化的已存页。
  List<int> get changedPages => <int>[
    for (final p in pages)
      if (p.changed) p.page,
  ];

  List<int> get failedPages => <int>[
    for (final p in pages)
      if (p.failed) p.page,
  ];

  /// 首页（含目录）是否变了 —— 单独拎出来说，因为首楼一动目录就跟着动。
  bool get firstPageChanged => pages.any((p) => p.page == 1 && p.changed);
}

/// 逐页核对**已离线保存的**页（2026-11-25）。
///
/// 口径（用户拍板）：
/// * 只核对已存页 —— 没存过的页用户没打算要，不去打扰站点；
/// * **重比内容、不写指纹**：只写"上次检查时间 + 结论"，基线留在"本机内容"
///   那一份上。这样"第 2 页变了"会一直显示到用户真的重下为止；
/// * 第 1 页必然在已存页里（下载时锁定），它的 `totalPages` 就是站点当前页数；
/// * 单页失败不中断，如实记 `failed`，其余照查。
///
/// [onProgress] 每查完一页回调一次（done, total），弹层靠它写「正在检查 3/5 页」。
Future<ForumCheckReport> checkForumThread(
  String tid, {
  void Function(int done, int total)? onProgress,
}) async {
  final cache = YmCache.instance;
  final stored = cache
      .peekOfParent('forum', tid)
      .where((e) => e.state.isDone && e.order > 0)
      .toList()
    ..sort((a, b) => a.order - b.order);
  final meta = await cache.readMeta('forum', tid) ?? const <String, String>{};
  final storedTotal = int.tryParse(meta['total'] ?? '') ?? 0;
  final fps = await cache.readForumFingerprints(tid);
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final results = <ForumPageCheck>[];
  var totalPages = 0;
  for (var i = 0; i < stored.length; i++) {
    final page = stored[i].order;
    var result = YmForumPageFp.failed;
    var error = '';
    var at = fps[page]?.at ?? 0;
    try {
      final html = await fetchForumThreadHtml(tid, page: page);
      final data = parseThreadPage(html, tid: tid, page: page);
      if (data.posts.isEmpty) {
        throw YmHttpError('第 $page 页没有内容', code: 'PARSE');
      }
      if (data.totalPages > totalPages) totalPages = data.totalPages;
      final local = fps[page]?.fp ?? '';
      final fresh = forumPageFingerprint(data);
      if (local.isEmpty) {
        // 旧版本存下来的页没有基线：这一轮只记基线，不下"变了"的结论
        result = YmForumPageFp.first;
        await cache.putForumFingerprint(tid, page, fresh, at: now);
      } else if (fresh == local) {
        result = YmForumPageFp.same;
        at = now;
      } else {
        result = YmForumPageFp.changed;
        at = now;
      }
      if (result != YmForumPageFp.first) {
        await cache.markForumChecked(tid, page, last: result, at: now);
      }
    } catch (e) {
      error = e is YmHttpError ? e.message : '第 $page 页检查失败';
      await cache.markForumChecked(
        tid,
        page,
        last: YmForumPageFp.failed,
      );
    }
    results.add(
      ForumPageCheck(
        page: page,
        result: result,
        checkedAt: at,
        error: error,
      ),
    );
    onProgress?.call(i + 1, stored.length);
  }

  if (totalPages > 0) {
    // 「上次检查时站点是多少页」单独记一个字段：可下载名单与"新增页"都靠它，
    // 但**不能覆盖** `total`（那是"上次保存"的基准，改了就没有"新增"可比了）。
    await cache.writeMeta('forum', tid, <String, String>{
      ...meta,
      'checkedTotal': '$totalPages',
    });
  }

  return ForumCheckReport(
    totalPages: totalPages,
    storedTotal: storedTotal,
    pages: results,
  );
}

/// 帖子一页的**原文**（只走网络，不解析、不落盘）。
///
/// 给下载队列用：队列自己决定什么时候写盘、写完标什么状态。
Future<String> fetchForumThreadHtml(String tid, {int page = 1}) async {
  final res = await ForumHttp.instance.request(
    '/forum.php?mod=viewthread&tid=$tid&page=$page&mobile=2',
    referer: '$kForumBase/forum.php?mod=viewthread&tid=$tid&mobile=2',
  );
  return res.body;
}

/// 读本机副本并解析；没有 / 坏档 / 索引没就绪一律 null。
///
/// **不 await 目录解析与索引载入**：读路径上多等一个平台通道，widget 测试里
/// 就永远回不来（缓存第一期 §6 的坑），页面会卡在 loading。
Future<ForumThreadPage?> readCachedForumThread(
  String tid, {
  required int page,
}) async {
  final cache = YmCache.instance;
  if (!cache.dirReady || !cache.indexLoaded) return null;
  if (!(cache.peek('forum:$tid:$page')?.state.isDone ?? false)) return null;
  final html = await cache.readHtml('forum:$tid:$page');
  if (html == null) return null;
  try {
    final data = parseThreadPage(html, tid: tid, page: page);
    // 副本解析不出楼层 = 存坏了 / 存的是消息页：当没有，别给一张空帖
    if (data.posts.isEmpty) return null;
    return data.copyWith(fromCache: true);
  } catch (_) {
    return null;
  }
}

/// 论坛图原始字节（下载侧用）：与渲染侧**同一套头**（`forumImageHeaders`）。
///
/// 不吃 `YmImageBytes` 的默认 PC UA：论坛图对请求头敏感（UA / Cookie / Referer
/// 三者任缺其一都可能被拒），须与渲染侧保持一致。
Future<Uint8List> fetchForumImageBytes(String url) =>
    YmImageBytes.fetch(url, headers: forumImageHeaders());

/// 在**已下载**的页里找某一楼在哪一页（离线兜底）。
///
/// 存在理由（2026-11-24 真机反馈）：论坛阅读器每读一章都要先 `resolveFindpost`
/// 拿服务端算好的页码，那是一次纯网络请求 —— 断网时已下载的帖子也读不进去。
/// 离线时用这份「本机目录」顶替：把存过的页逐页解析，pid 命中就返回页码。
///
/// 只在 `done` 的页里找；找不到返回 null（调用方照旧报错，不编页码）。
/// 一页几十 KB、解析是毫秒级，且只在首次进章时扫，不逐帧调用。
Future<int?> cachedForumPageOfPost(String tid, String pid) async {
  if (pid.isEmpty) return null;
  final cache = YmCache.instance;
  // 目录没就绪 / 索引没载入 = 这台机器上没有离线副本，别去等平台通道
  if (!cache.dirReady || !cache.indexLoaded) return null;
  final pages = cache
      .peekOfParent('forum', tid)
      .where((e) => e.state.isDone && e.order > 0)
      .toList()
    ..sort((a, b) => a.order - b.order);
  for (final entry in pages) {
    final html = await cache.readHtml('forum:$tid:${entry.order}');
    if (html == null) continue;
    try {
      final data = parseThreadPage(html, tid: tid, page: entry.order);
      if (data.posts.any((p) => p.pid == pid)) return entry.order;
    } catch (_) {
      // 这一页存坏了：跳过，当它没有
    }
  }
  return null;
}

/// findpost 跳楼解析结果：服务端算好的帖子 + 页码（楼层本身必在这一页里）。
class ForumFindpostTarget {
  const ForumFindpostTarget({required this.tid, required this.page, required this.pid});
  final String tid;
  final int page;
  final String pid;
}

/// findpost 重定向解析（0.1.22 拍板：正文内链走原生 A 路线 + 精准跳楼）。
///
/// 2026-11-15 实测（533721 / 535389 / 553860 多页回验，一页不差）：
/// GET `forum.php?mod=redirect&goto=findpost&pid=N&mobile=2` → 301，
/// `Location: viewthread&tid=T&page=P&mobile=2#pidN`——页码由服务端按楼层位置
/// 算好，原生不用自己算 pid→页码。游客锁板块 302 到 member.php → 按登录要求报。
Future<ForumFindpostTarget> resolveFindpost(String pid) async {
  final res = await ForumHttp.instance.request(
    '/forum.php?mod=redirect&goto=findpost&pid=$pid&mobile=2',
    redirectOk: true,
  );
  final loc = res.location ?? '';
  if (loc.contains('member.php?mod=logging')) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  final tid = RegExp(r'[?&]tid=(\d+)').firstMatch(loc)?.group(1);
  final page = int.tryParse(RegExp(r'[?&]page=(\d+)').firstMatch(loc)?.group(1) ?? '');
  if (tid == null || tid.isEmpty) {
    // 站点没按预期重定向（帖子没了 / 消息页）：不编目标，给人话报错
    throw YmHttpError('没能找到那一楼', code: 'HTTP');
  }
  return ForumFindpostTarget(tid: tid, page: page ?? 1, pid: pid);
}

/* ------------------------------ 个人资料 ------------------------------ */

/// 资料页的进程内缓存：是**别人**的资料、积分会变，所以不落盘；
/// 上限 12 条，超出挤掉最久没用过的那条（自己回看几个人够用，不做常驻）。
final Map<String, ForumProfile> _profileCache = <String, ForumProfile>{};
const int _profileCacheLimit = 12;

/// 页面要用的 uid：传了就用传的，没传就是我自己（登录态里的 uid）。
String _profileTarget(String uid) =>
    uid.isNotEmpty ? uid : ForumSession.account.value.uid;

/// 一个人的资料页。[uid] 空 = 我自己。
///
/// 失败口径：未登录时站点 302 跳登录，由通道抛 `LOGIN_REQUIRED`；
/// 「用户空间不存在」是 200 的消息页，解析认不出结构后走 `SITE_MESSAGE`
/// 把站点原文透传上去；其余认不出结构的情况是 `PARSE`。
Future<ForumProfile> fetchForumProfile({String uid = ''}) async {
  final target = _profileTarget(uid);
  final key = target.isNotEmpty ? target : 'self';
  final cached = _profileCache.remove(key);
  if (cached != null) {
    _profileCache[key] = cached; // 命中就算用过一次：挪到队尾
    return cached;
  }

  final query = target.isEmpty ? '' : '&uid=$target';
  final res = await ForumHttp.instance.request(
    '/home.php?mod=space$query&mycenter=1&mobile=2',
  );

  ForumProfile? parsed;
  try {
    parsed = parseUserProfile(res.body, uid: target);
  } catch (_) {
    // 先看是不是站方的消息页（「用户空间不存在」也是 200），不是再原样上抛
    _throwIfSiteMessage(res.body, nothingRecognized: true);
    rethrow;
  }

  _profileCache[key] = parsed;
  while (_profileCache.length > _profileCacheLimit) {
    _profileCache.remove(_profileCache.keys.first);
  }
  return parsed;
}

/// 某人「发表的主题」第一页（站点自己分页，本页十几条）。
///
/// 与板块页共用同一套行解析：空间页的主题列表行与 `forumdisplay` 同构
/// （`li.list` + `threadlist_top/tit/mes/foot`），只取 `threads`，
/// 不取空间页上那个「甲用户 - Ta的主题」标题当板块名。
Future<List<ForumThreadSummary>> fetchForumProfileThreads(String uid) async {
  final target = _profileTarget(uid);
  final query = target.isEmpty ? '' : '&uid=$target';
  final res = await ForumHttp.instance.request(
    '/home.php?mod=space$query&do=thread&view=me&order=dateline&mobile=2',
  );
  final data = parseBoardPage(res.body, fid: '', page: 1);
  _throwIfSiteMessage(res.body, nothingRecognized: data.threads.isEmpty);
  return data.threads;
}
