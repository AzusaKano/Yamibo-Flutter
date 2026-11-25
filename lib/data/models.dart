class YmPick {
  const YmPick({required this.id, required this.title, required this.line, required this.cover});
  final String id;
  final String title;
  final String line;
  final String cover;
}

class YmLatest {
  const YmLatest({
    required this.id,
    required this.cat,
    required this.title,
    required this.chapter,
    required this.author,
    required this.time,
    this.chapterId = '',
  });
  final String id;
  final String cat;
  final String title;
  final String chapter;
  final String author;
  final String time;
  final String chapterId;
}

class YmMangaLatest {
  const YmMangaLatest({
    required this.id,
    required this.title,
    required this.cover,
    required this.cat,
    required this.author,
  });
  final String id;
  final String title;
  final String cover;
  final String cat;
  final String author;
}

class YmWork {
  const YmWork({
    required this.id,
    required this.title,
    required this.author,
    required this.cat,
    required this.status,
    required this.license,
    required this.updatedAt,
    this.intro = '',
    this.heat = 0,
  });
  final String id;
  final String title;
  final String author;
  final String cat;
  final String status;
  final String license;
  final String updatedAt;
  final String intro;
  final int heat;
}

class YmManga {
  const YmManga({
    required this.id,
    required this.title,
    required this.author,
    required this.cat,
    required this.status,
    required this.updatedAt,
  });
  final String id;
  final String title;
  final String author;
  final String cat;
  final String status;
  final String updatedAt;
}

class YmChapterRef {
  const YmChapterRef({required this.id, required this.title, required this.volume});
  final String id;
  final String title;
  final String volume;
}

class YmVolume {
  const YmVolume({required this.name, required this.chapters});
  final String name;
  final List<YmChapterRef> chapters;
}

class YmNovelDetail {
  const YmNovelDetail({
    required this.id,
    required this.title,
    required this.author,
    required this.cat,
    required this.status,
    required this.license,
    required this.publishedAt,
    required this.updatedAt,
    required this.hits,
    required this.favs,
    required this.score,
    required this.tags,
    required this.intro,
    required this.notice,
    required this.cover,
    required this.latestChapter,
    required this.chapters,
    this.csrfToken = '',
    this.favored = false,
  });

  final String id;
  final String title;
  final String author;
  final String cat;
  final String status;
  final String license;
  final String publishedAt;
  final String updatedAt;
  final String hits;
  final String favs;
  final String score;
  final List<String> tags;
  final String intro;
  final String notice;
  final String cover;
  final String latestChapter;
  final List<YmChapterRef> chapters;

  /// 写操作要用的 CSRF token（来自页面 `<meta name="csrf-token">` 或隐藏 input）。
  /// 详情 / 章节页面已经取过，顺手带回来 ⇒ 加收藏、加书签不必再发一次 GET 换 token。
  /// 空串 = 页面里没找到，调用方需自行重取。
  final String csrfToken;

  /// 是否**已收藏**。站点把它写在 `#btnFav` 的标签文案里（`加入收藏` / `取消收藏`），
  /// 没有单独字段。收藏接口是**翻转**语义 ⇒ 不知道当前状态就会把用户的操作抵消掉。
  final bool favored;

  int get chapterCount => chapters.length;

  /// 按连续的 volume 字段分组；无卷名时归入「全部章节」。
  List<YmVolume> get volumes {
    final out = <YmVolume>[];
    for (final c in chapters) {
      final name = c.volume.isEmpty ? '全部章节' : c.volume;
      if (out.isEmpty || out.last.name != name) {
        out.add(YmVolume(name: name, chapters: [c]));
      } else {
        out.last.chapters.add(c);
      }
    }
    return out;
  }
}

class YmChapterContent {
  const YmChapterContent({
    required this.id,
    required this.title,
    required this.workId,
    required this.workTitle,
    required this.author,
    required this.paragraphs,
    required this.prev,
    required this.next,
    required this.words,
    this.csrfToken = '',
  });

  final String id;
  final String title;
  final String workId;
  final String workTitle;
  final String author;
  final List<String> paragraphs;
  final String prev;
  final String next;
  final String words;

  /// 写操作要用的 CSRF token（来自页面 `<meta name="csrf-token">` 或隐藏 input）。
  /// 详情 / 章节页面已经取过，顺手带回来 ⇒ 加收藏、加书签不必再发一次 GET 换 token。
  /// 空串 = 页面里没找到，调用方需自行重取。
  final String csrfToken;
}

class YmRankItem {
  const YmRankItem({
    required this.id,
    required this.rank,
    required this.title,
    required this.author,
    required this.cat,
    required this.status,
    required this.license,
  });
  final String id;
  final int rank;
  final String title;
  final String author;
  final String cat;
  final String status;
  final String license;
}

class YmRcmdItem {
  const YmRcmdItem({
    required this.id,
    required this.title,
    required this.intro,
    required this.createdAt,
  });
  final String id;
  final String title;
  final String intro;
  final String createdAt;
}

class YmMangaDetail {
  const YmMangaDetail({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
    required this.translator,
    required this.cat,
    required this.status,
    required this.license,
    required this.region,
    required this.version,
    required this.form,
    required this.publishedAt,
    required this.updatedAt,
    required this.hits,
    required this.favs,
    required this.score,
    required this.intro,
    required this.chapters,
    this.csrfToken = '',
    this.favored = false,
  });

  final String id;
  final String title;
  final String cover;
  final String author;
  final String translator;
  final String cat;
  final String status;
  final String license;
  final String region;
  final String version;
  final String form;
  final String publishedAt;
  final String updatedAt;
  final String hits;
  final String favs;
  final String score;
  final String intro;
  final List<YmChapterRef> chapters;

  /// 写操作要用的 CSRF token（来自页面 `<meta name="csrf-token">` 或隐藏 input）。
  /// 详情 / 章节页面已经取过，顺手带回来 ⇒ 加收藏、加书签不必再发一次 GET 换 token。
  /// 空串 = 页面里没找到，调用方需自行重取。
  final String csrfToken;

  /// 是否**已收藏**。站点把它写在 `#btnFav` 的标签文案里（`加入收藏` / `取消收藏`），
  /// 没有单独字段。收藏接口是**翻转**语义 ⇒ 不知道当前状态就会把用户的操作抵消掉。
  final bool favored;

  int get chapterCount => chapters.length;
}

class YmMangaPageSample {
  const YmMangaPageSample({
    required this.title,
    required this.workId,
    required this.chapterId,
    required this.nextChapterId,
    required this.page,
    required this.totalPages,
    this.image = '',
    this.csrfToken = '',
  });
  final String title;
  final String workId;
  final String chapterId;
  final String nextChapterId;
  final int page;
  final int totalPages;
  final String image;

  /// 写操作要用的 CSRF token（来自页面 `<meta name="csrf-token">` 或隐藏 input）。
  /// 详情 / 章节页面已经取过，顺手带回来 ⇒ 加收藏、加书签不必再发一次 GET 换 token。
  /// 空串 = 页面里没找到，调用方需自行重取。
  final String csrfToken;
}

/* ------------------------------ 结果类型 ----------------------------- */

class YmHomeFeed {
  const YmHomeFeed({required this.picks, required this.latest});
  final List<YmPick> picks;
  final List<YmLatest> latest;
}

class YmMangaHomeFeed {
  const YmMangaHomeFeed({required this.picks, required this.latest});
  final List<YmPick> picks;
  final List<YmMangaLatest> latest;
}

class YmListFeed {
  const YmListFeed({
    required this.items,
    required this.total,
    required this.page,
    required this.totalPages,
  });
  final List<YmWork> items;
  final int total;
  final int page;
  final int totalPages;
}

class YmRankFeed {
  const YmRankFeed({required this.items, required this.loginRequired});
  final List<YmRankItem> items;
  final bool loginRequired;
}

class YmSearchFeed {
  const YmSearchFeed({
    required this.items,
    required this.total,
    required this.page,
    required this.totalPages,
    required this.pageSize,
    required this.loginRequired,
  });
  final List<YmWork> items;
  final int total;
  final int page;
  final int totalPages;
  final int pageSize;
  final bool loginRequired;
}

class YmMangaListFeed {
  const YmMangaListFeed({
    required this.items,
    required this.total,
    required this.page,
    required this.totalPages,
    required this.pageSize,
    required this.loginRequired,
  });
  final List<YmManga> items;
  final int total;
  final int page;
  final int totalPages;
  final int pageSize;
  final bool loginRequired;
}

class YmRcmdsFeed {
  const YmRcmdsFeed({
    required this.items,
    required this.total,
    required this.page,
    required this.totalPages,
    required this.pageSize,
    required this.loginRequired,
  });
  final List<YmRcmdItem> items;
  final int total;
  final int page;
  final int totalPages;
  final int pageSize;
  final bool loginRequired;
}

class YmMangaDetailResult {
  const YmMangaDetailResult({required this.detail, required this.loginRequired});
  final YmMangaDetail detail;
  final bool loginRequired;
}

class YmMangaChapterResult {
  const YmMangaChapterResult({required this.page, required this.loginRequired});
  final YmMangaPageSample page;
  final bool loginRequired;
}

class YmMyInfo {
  const YmMyInfo({required this.loggedIn, required this.name, required this.uid});
  final bool loggedIn;
  final String name;
  final String uid;
}

/* ------------------------------ 站内书签 ----------------------------- */

/// 一条站内书签（`/my/bookmark`）。
///
/// ⚠ 一条书签**绑一章**，但一本书只保留一条（唯一性在「用户 × 作品」）——
/// 所以在列表里表现成「每本作品一行：最近标记到第几话」。
///
/// ⚠ 条目里**没有 workId、没有封面**：作品列是纯文字，章节 id 只在末列播放链接里，
/// 行属性只有 `data-key`（书签记录自增 id，既不是 workId 也不是 chptId）。
/// 想打开作品必须先由 [chaptId] 换出 workId（见 `api.fetchChapter` 的 `YmChapterContent.workId`）。
class YmBookmarkItem {
  const YmBookmarkItem({
    required this.dataKey,
    required this.chaptId,
    required this.chaptTitle,
    required this.workTitle,
    required this.author,
    required this.manga,
    this.page = 1,
  });

  /// 书签记录 id（`tr[data-key]`）。只用来去重 / 调试，**不能当作品或章节 id 用**。
  final String dataKey;

  final String chaptId;

  /// 章节名。小说形如 `第1章 一切的开始`，漫画形如 `001 月味之吻`（三位编号）。
  /// ⚠ 两种格式不同，别写死。
  final String chaptTitle;

  /// 作品名，已去掉 `[原创小说]` / `[原创漫画]` / `[同人]` 这类前缀。
  final String workTitle;

  final String author;

  /// 小说 / 漫画。由末列链接的路径判（`/novel/` vs `/manga/`），
  /// **不靠作品名的方括号前缀**（那是文案，不是字段）。
  final bool manga;

  /// 漫画页码（从末列链接的 `&page=` 抠出来）；小说恒 1。
  final int page;
}

/// 书签列表一页。
class YmBookmarkFeed {
  const YmBookmarkFeed({
    required this.items,
    required this.total,
    this.page = 1,
  });

  final List<YmBookmarkItem> items;

  /// 站点给的总条数（页脚「共 N 条」）。页面上没有这句时为 0（当作「就这一页」）。
  final int total;

  final int page;

  /// 除这一页之外还有没有更多（用来决定要不要显示「加载更多」）。
  bool get hasMore => total > 0 && items.length < total;
}

/* ------------------------------ 我的收藏 ----------------------------- */

/// 一条站内收藏（`/my/fav`）。
///
/// 与 [YmBookmarkItem] **刚好相反**：这里是 `list-view` 卡片流，**有 workId 也有封面**，
/// 拿到的就是作品本身；缺的是「读到哪」（阅读进度只存在于本机历史）。
class YmFavItem {
  const YmFavItem({
    required this.workId,
    required this.title,
    required this.author,
    required this.manga,
    this.cover = '',
    this.category = '',
    this.status = '',
    this.updatedAt = '',
    this.latestChapterId = '',
    this.latestChapterTitle = '',
  });

  final String workId;
  final String title;
  final String author;

  /// 小说 / 漫画。由作品链接的路径判（`/novel/` vs `/manga/`）。
  final bool manga;

  /// 封面**绝对地址**（站点给的是 `/covern/…`、`/coverm/…` 相对路径）。
  final String cover;

  /// 分类（`原创小说` / `同人` / …）。
  final String category;

  /// 作品状态（`连载中` / `已完结`）。
  final String status;

  /// 更新时间，站点原文（`2024-01-20`）。
  final String updatedAt;

  /// 「最近更新」那一章的 id 与标题。
  final String latestChapterId;
  final String latestChapterTitle;
}

/// 收藏列表一页。站点每页固定 10 篇（`?per-page=10` 是页面写死的，不是参数）。
class YmFavFeed {
  const YmFavFeed({
    required this.items,
    required this.total,
    this.page = 1,
    this.csrfToken = '',
  });

  final List<YmFavItem> items;

  /// 页脚「共 N 篇」。
  final int total;

  final int page;

  /// 这一页的 CSRF token。取消收藏要它 —— 顺手从页面 meta 里取，省一次回源。
  final String csrfToken;

  static const int pageSize = 10;

  bool get hasMore => items.isNotEmpty && page * pageSize < total;
}
