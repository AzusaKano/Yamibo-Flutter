import '../models.dart';
import '../parser.dart';
import 'ym_cache_store.dart';

/// 断网时的作品详情：**先读本地那份详情页原文**（第四期选项 D），
/// 没有副本（老数据）才退回「从磁盘索引合成」（第三期任务 A，2026-11-24）。
///
/// 为什么分两层：详情页要的东西（简介 / 标签 / 收藏数 / 完整目录）只有站点页面
/// 才有，索引里只有「哪几章存过」。所以
/// * 有副本 ⇒ 照在线同一套 parser 解出来，页面几乎和在线一样；
/// * 没副本 ⇒ 退回索引合成（目录只含已存章），保证「离线内容子页点一行能读」
///   这条第三期的口径在旧数据上继续成立。
Future<YmNovelDetail?> ymOfflineNovelDetail(
  String parent, {
  String title = '',
}) async {
  final local = await _novelFromLocalDetail(parent);
  if (local != null) return local;
  return _novelFromIndex(parent, title: title);
}

Future<YmMangaDetail?> ymOfflineMangaDetail(
  String parent, {
  String title = '',
}) async {
  final local = await _mangaFromLocalDetail(parent);
  if (local != null) return local;
  return _mangaFromIndex(parent, title: title);
}

/* ------------------------- 优先：本机详情页原文 ------------------------- */

/// 有网时存下来的详情页原文 → detail。坏档 / 解析不出书名 / 登录页一律当没有。
Future<YmNovelDetail?> _novelFromLocalDetail(String parent) async {
  final html = await YmCache.instance.readDetailHtml('novel', parent);
  if (html == null) return null;
  try {
    final data = parseDetail(html, parent);
    return data.title.isEmpty ? null : data;
  } catch (_) {
    return null;
  }
}

Future<YmMangaDetail?> _mangaFromLocalDetail(String parent) async {
  final html = await YmCache.instance.readDetailHtml('manga', parent);
  if (html == null) return null;
  try {
    final result = parseMangaDetail(html, parent);
    if (result.loginRequired || result.detail.title.isEmpty) return null;
    return result.detail;
  } catch (_) {
    return null;
  }
}

/* -------------------------- 兜底：从索引合成 -------------------------- */

/// 没有详情页副本时的兜底：用索引里的 unit 拼出阅读器能认的 detail。
///
/// 三条口径：
/// * **目录只列已存的章 / 话**：诚实，不把没下过的章塞进去再报错；
/// * `id` 必须是**真实作品 id**（= unit 的 `parent`），否则历史 / 进度会写成另一条；
/// * 其余字段尽量从 `meta/<source>-<parent>.json` 补（`author` / `cat` / 漫画 `form`），
///   补不到的给空 / 0 —— 不编。
Future<YmNovelDetail?> _novelFromIndex(
  String parent, {
  String title = '',
}) async {
  final chapters = await _offlineChapters('novel', parent);
  if (chapters.isEmpty) return null;
  final meta = await YmCache.instance.readMeta('novel', parent) ?? const <String, String>{};
  return YmNovelDetail(
    id: parent,
    title: title.isEmpty ? _titleOf('novel', parent) : title,
    author: meta['author'] ?? '',
    cat: meta['cat'] ?? '',
    status: '',
    license: '',
    publishedAt: '',
    updatedAt: '',
    hits: '',
    favs: '',
    score: '',
    tags: const <String>[],
    intro: '',
    notice: '',
    // 封面 URL 带签名、不能长期复用；本机封面由 `YmCache.peekCoverFile` 单独给
    // 渲染侧用（离线内容页），这里不塞一个假 URL。
    cover: '',
    latestChapter: chapters.last.title,
    chapters: chapters,
    // 离线没有页面可拿 csrfToken：书签点击会走登录判定并提示，
    // 这是**正确行为**，不做假成功。
    csrfToken: '',
    favored: false,
  );
}

Future<YmMangaDetail?> _mangaFromIndex(
  String parent, {
  String title = '',
}) async {
  final chapters = await _offlineChapters('manga', parent);
  if (chapters.isEmpty) return null;
  final meta = await YmCache.instance.readMeta('manga', parent) ?? const <String, String>{};
  return YmMangaDetail(
    id: parent,
    title: title.isEmpty ? _titleOf('manga', parent) : title,
    cover: '',
    author: meta['author'] ?? '',
    translator: '',
    cat: meta['cat'] ?? '',
    status: '',
    license: '',
    region: '',
    version: '',
    // `form` 决定条漫还是分页（`manga_reader_page.dart` 首帧就按它分形态）：
    // 丢了会让条漫作品按分页打开，所以元信息里必须留着（第三期任务 B 顺带存的）。
    form: meta['form'] ?? '',
    publishedAt: '',
    updatedAt: '',
    hits: '',
    favs: '',
    score: '',
    intro: '',
    chapters: chapters,
    csrfToken: '',
    favored: false,
  );
}

/// 已落账（`done`）的 unit → 阅读器要的章节列表，按 `order` 升序。
///
/// unit 的章节 id 只能从 `key` 拆（`novel:<id>` / `manga:<id>`）：
/// `YmCacheEntry` 没有单独的 `chaptId` 字段，拆不出来就跳过那一条。
Future<List<YmChapterRef>> _offlineChapters(
  String source,
  String parent,
) async {
  // 目录没就绪 / 索引还没读进内存 = 这台机器上现在没有已存章节，直接当没有；
  // 别为了一本没下过的书去异步读索引 —— 那会把详情页首屏卡在 loading 上。
  if (!YmCache.instance.dirReady || !YmCache.instance.indexLoaded) {
    return const <YmChapterRef>[];
  }
  await YmCache.load();
  final entries = await YmCache.instance.entriesOfParent(source, parent);
  final chapters = <YmChapterRef>[];
  for (final e in entries) {
    if (!e.state.isDone) continue;
    // unit 的章节 id 只能从 key 拆（`novel:<id>` / `manga:<id>`）：`YmCacheEntry`
    // 没有单独的 `chaptId` 字段，拆不出来（没有冒号 / 冒号后面是空）就跳过该条。
    final sep = e.key.indexOf(':');
    if (sep <= 0 || sep >= e.key.length - 1) continue;
    final id = e.key.substring(sep + 1);
    if (id.isEmpty) continue;
    // 卷名留空：离线子页本来就是扁平清单，合成 detail 里不插分卷标题行
    chapters.add(YmChapterRef(id: id, title: e.title, volume: ''));
  }
  return chapters;
}

/// 作品名：优先用任何一个已存 unit 上记着的 `parentTitle`（离线页传进来的
/// 也是同一个值，两处一致即可）。
String _titleOf(String source, String parent) {
  for (final e in YmCache.instance.peekOfParent(source, parent)) {
    if (e.parentTitle.isNotEmpty) return e.parentTitle;
  }
  return '';
}
