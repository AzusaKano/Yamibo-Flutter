import 'dart:async';

import 'cache/ym_cache_store.dart';
import 'http.dart';
import 'models.dart';
import 'parser.dart';

/// 站点接口层：请求 + 解析 + 进程内缓存（与 uni 版 `services/api.js` 对齐）。
///
/// 页面只依赖这一层，不直接拼 URL、也不直接碰 HTML。
/// 失败一律是 [YmHttpError]：`isLoginRequired` 决定是否切「登录后使用」提示屏。

class _Entry {
  _Entry(this.at, this.value, this.ttl);
  final DateTime at;
  final Object value;
  final Duration ttl;
}

class _Cache {
  final Map<String, _Entry> _map = <String, _Entry>{};
  static const int _max = 80;

  Object? get(String key) {
    final hit = _map[key];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.at) > hit.ttl) {
      _map.remove(key);
      return null;
    }
    return hit.value;
  }

  T put<T extends Object>(String key, T value, Duration ttl) {
    _map[key] = _Entry(DateTime.now(), value, ttl);
    if (_map.length > _max) {
      _map.remove(_map.keys.first);
    }
    return value;
  }

  void remove(String key) => _map.remove(key);

  /// 按前缀作废（写操作后用，如收藏完作废 `detail:264784`）。
  void evictPrefix(String prefix) {
    _map.removeWhere((key, _) => key.startsWith(prefix));
  }

  void clear() => _map.clear();
}

final _Cache _cache = _Cache();

const _ttlHome = Duration(minutes: 2);
const _ttlList = Duration(minutes: 1);
const _ttlDetail = Duration(minutes: 5);
const _ttlChapter = Duration(minutes: 10);
const _ttlSearch = Duration(minutes: 1);

String _params(Map<String, Object?> obj) => obj.entries
    .where((e) => e.value != null && '${e.value}'.isNotEmpty)
    .map((e) =>
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent('${e.value}')}')
    .join('&');

Never _fail(String message, {String code = 'PARSE'}) =>
    throw YmHttpError(message, code: code);

/* --------------------------------- 首页 -------------------------------- */

Future<YmHomeFeed> fetchNovelHome() async {
  const key = 'home:novel';
  final hit = _cache.get(key);
  if (hit is YmHomeFeed) return hit;

  final html = await YmHttp.instance.requestText('/site/novel');
  final data = parseHome(html);
  if (data.picks.isEmpty && data.latest.isEmpty) {
    _fail('页面结构解析失败，请稍后重试');
  }
  _cache.put(key, data, _ttlHome);
  return data;
}

Future<YmMangaHomeFeed> fetchMangaHome() async {
  const key = 'home:manga';
  final hit = _cache.get(key);
  if (hit is YmMangaHomeFeed) return hit;

  final html = await YmHttp.instance.requestText('/site/manga');
  final data = parseMangaHome(html);
  if (data.picks.isEmpty && data.latest.isEmpty) {
    _fail('页面结构解析失败，请稍后重试');
  }
  _cache.put(key, data, _ttlHome);
  return data;
}

/* --------------------------------- 列表 -------------------------------- */

Future<YmListFeed> fetchList({
  String q = '',
  int page = 1,
  String sort = '-updated_at',
}) async {
  final key = 'list:$q:$page:$sort';
  final hit = _cache.get(key);
  if (hit is YmListFeed) return hit;

  final query = _params({
    'q': q == 'all' ? '' : q,
    'page': page,
    'per-page': 50,
    'sort': sort,
  });
  final html = await YmHttp.instance
      .requestText('/novel/list${query.isEmpty ? '' : '?$query'}');
  final data = parseList(html, page);
  if (data.items.isEmpty && page == 1) {
    _fail('列表没有返回内容，请稍后重试');
  }
  _cache.put(key, data, _ttlList);
  return data;
}

/* --------------------------------- 详情 -------------------------------- */

Future<YmNovelDetail> fetchDetail(String id) async {
  final key = 'detail:$id';
  final hit = _cache.get(key);
  if (hit is YmNovelDetail) return hit;

  final html = await YmHttp.instance.requestText('/novel/${Uri.encodeComponent(id)}');
  final data = parseDetail(html, id);
  if (data.title.isEmpty) _fail('作品详情解析失败');
  _cache.put(key, data, _ttlDetail);
  _rememberDetailHtml('novel', id, html);
  _mirrorDetailHtml('novel', id, html);
  return data;
}

/// 最近取到的详情页原文（内存 LRU，键 `source:id`）。
///
/// 用途只有一个：用户在这本书的详情页上点「离线」下载时，把**刚看到的那份原文**
/// 顺手落到本地（第四期选项 D），而不是再为它发一次请求 —— 少一次流量，
/// 也不会让队列里多出一条「非正文」请求。
final Map<String, String> _detailHtmlMemo = <String, String>{};

/// 只记最近 20 本：够覆盖「看完详情立刻下载」这个真实用法。
const int _detailMemoMax = 20;

void _rememberDetailHtml(String source, String id, String html) {
  final key = '$source:$id';
  _detailHtmlMemo
    ..remove(key)
    ..[key] = html;
  if (_detailHtmlMemo.length > _detailMemoMax) {
    _detailHtmlMemo.remove(_detailHtmlMemo.keys.first);
  }
}

/// 取这本刚打开时的详情页原文；null = 这个进程里没取过（调用方别为此发请求）。
String? peekDetailHtml(String source, String id) => _detailHtmlMemo['$source:$id'];

/// 测试用：清掉原文备忘。
void clearDetailHtmlMemo() => _detailHtmlMemo.clear();

/// 详情页原文的本地副本（第四期选项 D）：**只给已经存过章节的书**留一份。
///
/// 口径（用户 2026-11-24 定）：下载这本时存一份，之后每次**有网**打开详情页
/// 都覆盖刷新一次，断网时直接读这份。
/// 没下过任何一章的书不写盘 —— 与「只有下载任务写盘」的老口径保持一致，
/// 免得随手看两眼就在手机里堆出几百 KB。
void _mirrorDetailHtml(String source, String id, String html) {
  if (YmCache.instance.peekOfParent(source, id).isEmpty) return;
  unawaited(YmCache.instance.writeDetailHtml(source, id, html));
}

/// 小说章节：内存缓存 → 磁盘原文 → 网络（统一口径）。
///
/// 只有「手动下载」过的章才在磁盘上；随手读一次不落盘。
/// 磁盘读失败 / 文件损坏 ⇒ 当未命中，静默回源，异常语义与改前一致。
Future<YmChapterContent> fetchChapter(String id) async {
  final key = 'chapter:$id';
  final hit = _cache.get(key);
  if (hit is YmChapterContent) return hit;

  final cached = await _readChapterFromDisk(id);
  if (cached != null) {
    // 从磁盘读出来的照样填回内存（同一套 TTL，不额外加时限）
    _cache.put(key, cached, _ttlChapter);
    return cached;
  }

  final html = await YmHttp.instance
      .requestText('/novel/view-chapter?id=${Uri.encodeQueryComponent(id)}');
  final data = parseChapter(html, id);
  if (data.title.isEmpty || data.paragraphs.isEmpty) {
    _fail('正文解析失败或章节不存在');
  }
  _cache.put(key, data, _ttlChapter);
  return data;
}

/// 章节页**原文**（下载任务专用，§任务 3）。
///
/// 存原文不存模型：下载时落盘的是站点返回的 HTML，读的时候重新走 parser。
/// ⚠ 这里**不重试**：重试只由下载队列做一次，两处都重试会叠成 4 次请求。
/// 解析校验只用来挡住「登录页 / 错误页」被当成正文存进缓存。
Future<String> fetchChapterHtml(String id) async {
  final res = await YmHttp.instance.request(
    '/novel/view-chapter?id=${Uri.encodeQueryComponent(id)}',
    priority: YmPriority.normal,
    retry: false,
  );
  final probe = parseChapter(res.body, id);
  if (probe.title.isEmpty || probe.paragraphs.isEmpty) {
    _fail('正文解析失败或章节不存在');
  }
  return res.body;
}

/// 磁盘命中：返回解析后的模型；未命中 / 坏文件 / 解析失败一律 null。
Future<YmChapterContent?> _readChapterFromDisk(String id) async {
  try {
    final html = await YmCache.instance.readHtml('novel:$id');
    if (html == null || html.isEmpty) return null;
    final data = parseChapter(html, id);
    if (data.title.isEmpty || data.paragraphs.isEmpty) return null;
    return data;
  } catch (_) {
    // 磁盘侧出任何问题都只当「没缓存」，不影响正常阅读
    return null;
  }
}

/* --------------------------------- 搜索 -------------------------------- */

/// 高级搜索（必须登录）。未登录时 [YmHttpError.isLoginRequired] 为 true。
Future<YmSearchFeed> searchAdvanced({
  String keyword = '',
  String author = '',
  String cat = '',
  String status = '',
  String type = '',
  int page = 1,
  String sort = '',
}) async {
  final key = 'adv:$keyword:$author:$cat:$status:$type:$page:$sort';
  final hit = _cache.get(key);
  if (hit is YmSearchFeed) return hit;

  final query = _params({
    'type': 1,
    'NovelSearchForm[workTitle]': keyword,
    'NovelSearchForm[uid]': author,
    'NovelSearchForm[nvStatus]': status,
    'NovelSearchForm[workCat]': cat,
    'NovelSearchForm[workType]': type,
    'page': page,
    'sort': sort,
  });
  final html = await YmHttp.instance.requestText('/search/adv-result?$query');
  final data = parseAdvancedSearch(html, page);
  if (data.loginRequired) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  _cache.put(key, data, _ttlSearch);
  return data;
}

/* --------------------------------- 排行 -------------------------------- */

Future<YmRankFeed> fetchRank({String kind = 'novel'}) async {
  final key = 'rank:$kind';
  final hit = _cache.get(key);
  if (hit is YmRankFeed) return hit;

  final html = await YmHttp.instance
      .requestText(kind == 'manga' ? '/manga/ranking' : '/novel/ranking');
  final data = parseRank(html);
  if (data.loginRequired) {
    throw YmHttpError('需要登录后才能看排行', code: 'LOGIN_REQUIRED');
  }
  _cache.put(key, data, _ttlDetail);
  return data;
}

/* --------------------------------- 漫画 -------------------------------- */

Future<YmMangaDetail> fetchMangaDetail(String id) async {
  final key = 'manga:$id';
  final hit = _cache.get(key);
  if (hit is YmMangaDetail) return hit;

  final html = await YmHttp.instance.requestText('/manga/${Uri.encodeComponent(id)}');
  final result = parseMangaDetail(html, id);
  if (result.loginRequired) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  if (result.detail.title.isEmpty) _fail('漫画详情解析失败');
  _cache.put(key, result.detail, _ttlDetail);
  _rememberDetailHtml('manga', id, html);
  _mirrorDetailHtml('manga', id, html);
  return result.detail;
}

/// 漫画章节页：一页一张图。
/// - [prefetch]：预取，优先级最低、失败不重试、可被交互请求作废；
/// - [force]：先踢缓存再回源（图片 403 / 签名失效时用）。**磁盘也跳过**：
///   `force` 的语义是「这张图的地址过期了要拿新的」，本地存着旧原文也没用
///   （第二期 2D，2026-11-24）。
///
/// 读取顺序：内存 → 磁盘页原文 → 网络。只有「手动下载过的一话」才在磁盘上。
Future<YmMangaPageSample> fetchMangaChapter(
  String id, {
  int page = 1,
  bool prefetch = false,
  bool force = false,
}) async {
  final key = 'manga-ch:$id:$page';
  if (force) {
    _cache.remove(key);
  } else {
    final hit = _cache.get(key);
    if (hit is YmMangaPageSample) return hit;

    final cached = await _readMangaPageFromDisk(id, page);
    if (cached != null) {
      // 从磁盘读出来的照样填回内存（同一套 TTL，不额外加时限）
      _cache.put(key, cached, _ttlChapter);
      return cached;
    }
  }

  final suffix = page > 1 ? '&page=$page' : '';
  final html = await YmHttp.instance.requestText(
    '/manga/view-chapter?id=${Uri.encodeQueryComponent(id)}$suffix',
    lane: YmLane.chapter,
    priority: prefetch ? YmPriority.prefetch : YmPriority.user,
  );
  final result = parseMangaChapter(html, page);
  if (result.loginRequired) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  if (result.page.image.isEmpty) _fail('这一页没有图片，章节可能不存在');
  _cache.put(key, result.page, _ttlChapter);
  return result.page;
}

/// 漫画某一页的**原文**（下载任务专用，第二期 2D）。
///
/// 与 [fetchChapterHtml] 同一套口径：**不重试**（重试只由下载队列做），
/// 用 parser 挡掉登录页 / 错误页，免得把坏原文写进缓存。
Future<String> fetchMangaPageHtml(String id, int page) async {
  final suffix = page > 1 ? '&page=$page' : '';
  final res = await YmHttp.instance.request(
    '/manga/view-chapter?id=${Uri.encodeQueryComponent(id)}$suffix',
    lane: YmLane.chapter,
    priority: YmPriority.normal,
    retry: false,
  );
  final probe = parseMangaChapter(res.body, page);
  if (probe.loginRequired) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  if (probe.page.image.isEmpty) _fail('这一页没有图片，章节可能不存在');
  return res.body;
}

/// 磁盘命中：返回解析后的页模型；未命中 / 坏文件 / 解析不出图一律 null
/// （当没缓存，静默回源，异常语义与改前一致）。
Future<YmMangaPageSample?> _readMangaPageFromDisk(String id, int page) async {
  try {
    final html = await YmCache.instance.readPageHtml(id, page);
    if (html == null || html.isEmpty) return null;
    final result = parseMangaChapter(html, page);
    if (result.loginRequired || result.page.image.isEmpty) return null;
    return result.page;
  } catch (_) {
    return null;
  }
}

Future<YmMangaListFeed> fetchMangaList({
  String bucket = '',
  String tag = '',
  int page = 1,
  String sort = '-updated_at',
}) async {
  final key = 'mg-list:$bucket:$tag:$page:$sort';
  final hit = _cache.get(key);
  if (hit is YmMangaListFeed) return hit;

  final path = tag.isNotEmpty
      ? '/search/type?${_params({'type': 3, 'tag': tag, 'page': page, 'sort': sort})}'
      : '/manga/list?${_params({'q': bucket, 'page': page, 'per-page': 50, 'sort': sort})}';
  final html = await YmHttp.instance.requestText(path);
  final data = parseMangaList(html, page);
  if (data.loginRequired) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  _cache.put(key, data, _ttlList);
  return data;
}

Future<YmRcmdsFeed> fetchRcmds({
  String kind = 'novel',
  int page = 1,
  String sort = '-created_at',
}) async {
  final key = 'rcmds:$kind:$page:$sort';
  final hit = _cache.get(key);
  if (hit is YmRcmdsFeed) return hit;

  final base = kind == 'manga' ? '/manga/rcmds' : '/novel/rcmds';
  final type = kind == 'manga' ? '3012' : '2012';
  final html = await YmHttp.instance
      .requestText('$base?${_params({'type': type, 'page': page, 'sort': sort})}');
  final data = parseRcmds(html, page);
  if (data.loginRequired) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  _cache.put(key, data, _ttlList);
  return data;
}

/* --------------------------------- 账号 -------------------------------- */

/// `/my` 的原始判定结果：账号视图 + 注销要用的 CSRF token。
///
/// **不进缓存**：登录态每次都要问站点，缓存会让「退出登录后还显示已登录」。
class YmMyPage {
  const YmMyPage({required this.info, required this.csrf});
  final YmMyInfo info;
  final String csrf;
}

/// 取 `/my`：登录态以它的真实返回为准（出现 `LoginForm[username]` = 未登录）。
Future<YmMyPage> fetchMy({bool retry = true}) async {
  final res = await YmHttp.instance.request(
    '/my',
    priority: YmPriority.user,
    retry: retry,
  );
  return YmMyPage(
    info: parseMyPage(res.body),
    csrf: parseCsrfToken(res.body),
  );
}

/// 站内书签列表（`/my/bookmark`）。**小说与漫画混排**，一次请求拿全，不必为合并发两次。
///
/// 条目里没有 workId / 封面（见 [YmBookmarkItem]），要打开作品得先用 `chaptId` 换。
/// 未登录：站点 302 到登录页（网络层按 `redirectOk=false` 抛 `LOGIN_REQUIRED`），
/// 这里再兜一层「200 但返回登录表单」。
Future<YmBookmarkFeed> fetchBookmarks({int page = 1, bool retry = true}) async {
  final key = 'bookmarks:$page';
  final hit = _cache.get(key);
  if (hit is YmBookmarkFeed) return hit;

  final res = await YmHttp.instance.request(
    page > 1 ? '/my/bookmark?page=$page' : '/my/bookmark',
    priority: YmPriority.user,
    retry: retry,
  );
  if (RegExp(r'name="LoginForm\[username\]"').hasMatch(res.body)) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  final feed = parseBookmarkList(res.body, page: page);
  _cache.put(key, feed, _ttlList);
  return feed;
}

/// 站内收藏列表（`/my/fav`）。**小说与漫画混排，站点没有类型过滤**，一次请求拿全。
///
/// 与书签相反：条目**有 workId 也有封面**，可以直接进详情页，不需要先换 id。
/// 每页固定 10 篇（`?per-page=10`），翻页用 `?page=N`。
/// 未登录的判法与 [fetchBookmarks] 相同：302 或「200 但是登录表单」。
Future<YmFavFeed> fetchFavs({int page = 1, bool retry = true}) async {
  final key = 'favs:$page';
  final hit = _cache.get(key);
  if (hit is YmFavFeed) return hit;

  final res = await YmHttp.instance.request(
    page > 1 ? '/my/fav?page=$page' : '/my/fav',
    priority: YmPriority.user,
    retry: retry,
  );
  if (RegExp(r'name="LoginForm\[username\]"').hasMatch(res.body)) {
    throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  }
  final feed = parseFavList(res.body, page: page);
  _cache.put(key, feed, _ttlList);
  return feed;
}

void clearCache() {
  _cache.clear();
  clearDetailHtmlMemo();
}

/// 写操作之后用：只作废受影响的那几项，不清全部（首页 / 列表与这次写无关，
/// 清了会让用户莫名多等一次网络）。
/// 例如加完收藏 → `evictCache('detail:264784')`，下次进详情拿到的是新收藏数。
void evictCache(String keyPrefix) => _cache.evictPrefix(keyPrefix);
