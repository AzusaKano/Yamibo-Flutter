import 'dart:math' as math;

import 'models.dart';

/// 百合会 HTML 解析器（纯函数）：与 uni 版 `services/parser.js` 一一对应。
/// 站点改版时集中修这里，用 `test/parser_test.dart` 的 probe 样本做回归。
const String _site = 'https://www.yamibo.com';

const Map<String, String> _entities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
  'mdash': '—', 'ndash': '–', 'hellip': '…', 'middot': '·', 'bull': '•',
  'ldquo': '“', 'rdquo': '”', 'lsquo': '‘', 'rsquo': '’',
  'laquo': '«', 'raquo': '»', 'copy': '©', 'reg': '®', 'trade': '™',
  'times': '×', 'divide': '÷', 'deg': '°', 'plusmn': '±',
  'frac12': '½', 'frac14': '¼', 'frac34': '¾',
  'ensp': ' ', 'emsp': ' ', 'thinsp': ' ',
  'rarr': '→', 'larr': '←', 'uarr': '↑', 'darr': '↓', 'harr': '↔',
  'rArr': '⇒', 'lArr': '⇐', 'hArr': '⇔', 'minus': '−', 'le': '≤', 'ge': '≥', 'ne': '≠',
};

String decodeEntities(String input) {
  return input.replaceAllMapped(
    RegExp(r'&(#x?[0-9a-f]+|[a-z][a-z0-9]+);', caseSensitive: false),
    (m) {
      final body = m[1]!;
      if (body.startsWith('#')) {
        final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final code = int.tryParse(body.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
        if (code != null && code > 0 && code <= 0x10ffff) {
          return String.fromCharCode(code);
        }
        return m[0]!;
      }
      return _entities[body.toLowerCase()] ?? m[0]!;
    },
  );
}

String stripTags(String input) {
  return decodeEntities(input.replaceAll(RegExp(r'<[^>]*>'), ' '))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String toText(String input) {
  final withBreaks = input
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</div>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  return decodeEntities(withBreaks)
      .replaceAll('\r', '')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String absolute(String url) {
  if (url.isEmpty) return '';
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return url;
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('/')) return '$_site$url';
  return '$_site/$url';
}

String _first(String html, RegExp re, [int index = 1]) {
  final m = re.firstMatch(html);
  if (m == null) return '';
  return index <= m.groupCount ? (m.group(index) ?? '') : '';
}

Iterable<RegExpMatch> _all(String html, RegExp re) => re.allMatches(html);

String workIdFromUrl(String url) =>
    _first(url, RegExp(r'/(?:novel|manga)/(\d+)'));

/// 详情页「我收藏了吗」。
///
/// 站点没有单独字段，状态只体现在 `#btnFav` 的**标签文案**上：未收藏 `加入收藏`、
/// 已收藏 `取消收藏`（内联 `addFav()` 的成功回调按 `data.status` 自己换文案）。
///
/// ⚠ 那个 `<button>` 的 `onclick` 里内联了整段 JS（含 `&#039;` 转义与 `</` 之类），
/// 所以不能直接 `stripTags` 整段 —— 先截到 `</button>`，再取**最后一次** `">`
/// 之后的那截（`onclick="…addFav(1,267267);">` 就结束在这儿），那才是标签文字。
///
/// ⚠ 与书签相反：`#btnMark` 的文案**不反映真实状态**（加过之后仍印「加书签」），
/// 而 `#btnFav` 的文案实测是准的（2026-10-25 三条证据之一）。
bool parseFavored(String html) {
  final at = html.indexOf('id="btnFav"');
  if (at < 0) return false;
  final end = html.indexOf('</button>', at);
  if (end < 0) return false;
  final seg = html.substring(at, end);
  final close = seg.lastIndexOf('">');
  if (close < 0) return false;
  return stripTags(seg.substring(close + 2)).contains('取消收藏');
}

String chapterIdFromUrl(String url) =>
    _first(url, RegExp(r'[?&]id=(\d+)'));

/* ------------------------------- 首页 ------------------------------- */

YmHomeFeed parseHome(String html) {
  final picks = <YmPick>[];
  final latest = <YmLatest>[];

  final pickStart = html.indexOf('编辑推荐');
  if (pickStart >= 0) {
    final pickEnd = html.indexOf('<!-- ./panel-body -->', pickStart);
    final block = html.substring(
      pickStart,
      pickEnd > 0 ? pickEnd : math.min(pickStart + 12000, html.length),
    );
    final cardRe = RegExp(
      r'<div class="col-(?:md|xs)-3 text-center">([\s\S]*?)<!-- \./col-(?:md|xs)-3 -->',
    );
    for (final m in _all(block, cardRe)) {
      final card = m[1]!;
      final href = _first(card, RegExp(r'<a href="([^"]+)"'));
      final id = workIdFromUrl(href);
      if (id.isEmpty) continue;
      picks.add(YmPick(
        id: id,
        title: stripTags(_first(card, RegExp(r'<h5>[\s\S]*?<a[^>]*>([\s\S]*?)</a>'))),
        line: stripTags(_first(card, RegExp(r'<p>([\s\S]*?)</p>'))),
        cover: absolute(_first(card, RegExp(r'<img[^>]*src="([^"]+)"'))),
      ));
    }
  }

  final latestStart = html.indexOf('最近更新');
  if (latestStart >= 0) {
    final block = html.substring(latestStart);
    for (final m in _all(block, RegExp(r'<tr>([\s\S]*?)</tr>'))) {
      final row = m[1]!;
      if (!row.contains('view-chapter?id=')) continue;
      final workHref = _first(row, RegExp(r'<a class="title-rest" href="([^"]+)"'));
      final titleRaw = stripTags(_first(
        row,
        RegExp(r'<a class="title-rest" href="/novel/\d+"[^>]*>([\s\S]*?)</a>'),
      ));
      final id = workIdFromUrl(workHref);
      if (id.isEmpty) continue;
      final catM = RegExp(r'^\[([^\]]+)\]\s*(.*)$').firstMatch(titleRaw);
      final chapterId = _first(row, RegExp(r'view-chapter\?id=(\d+)'));
      final chapter = stripTags(_first(
        row,
        RegExp(r'view-chapter\?id=\d+"[^>]*>([\s\S]*?)</a>'),
      ));
      final author = stripTags(_first(
        row,
        RegExp(r'/user/space\?id=\d+"[^>]*>([\s\S]*?)</a>'),
      ));
      final timeCells = _all(row, RegExp(r'<td class="text-warning">([\s\S]*?)</td>')).toList();
      final time = timeCells.isEmpty ? '' : stripTags(timeCells.last[1]!);
      latest.add(YmLatest(
        id: id,
        cat: catM?.group(1) ?? '',
        title: catM?.group(2) ?? titleRaw,
        chapterId: chapterId,
        chapter: chapter,
        author: author,
        time: time,
      ));
      if (latest.length >= 12) break;
    }
  }

  return YmHomeFeed(picks: picks, latest: latest);
}

YmMangaHomeFeed parseMangaHome(String html) {
  final picks = <YmPick>[];
  final latest = <YmMangaLatest>[];

  final pickStart = html.indexOf('编辑推荐');
  if (pickStart >= 0) {
    final block = html.substring(
      pickStart,
      math.min(pickStart + 16000, html.length),
    );
    final cardRe = RegExp(
      r'''<a class="media-img" href="([^"]+)" style="background-image:\s*url\((?:&#039;|\')([^\'&]+)(?:&#039;|\')\)"></a>[\s\S]*?<h3 class="recommend-title"><a[^>]*>([\s\S]*?)</a></h3>''',
    );
    for (final m in _all(block, cardRe)) {
      final id = workIdFromUrl(m[1]!);
      if (id.isEmpty) continue;
      picks.add(YmPick(
        id: id,
        title: stripTags(m[3]!),
        cover: absolute(m[2]!),
        line: '',
      ));
    }
  }

  final latestStart = html.indexOf('最近更新');
  if (latestStart >= 0) {
    final block = html.substring(latestStart);
    final cells = block.split('<div class="media-cell vertical">').skip(1);
    for (final cell in cells) {
      final href = _first(cell, RegExp(r'<a class="media-img" href="([^"]+)"'));
      final id = workIdFromUrl(href);
      if (id.isEmpty) continue;
      final cover = _first(
        cell,
        RegExp(r'''<a class="media-img" href="[^"]+" style="background-image:\s*url\((?:&#039;|\')([^\'&]+)(?:&#039;|\')\)"'''),
      );
      final title = stripTags(_first(
        cell,
        RegExp(r'<h3 class="two-line-ellipsis"><a[^>]*>([\s\S]*?)</a></h3>'),
      ));
      final cat = stripTags(_first(cell, RegExp(r'<div class="newest-label">([\s\S]*?)</div>')));
      final author = stripTags(_first(cell, RegExp(r'<p class="newest-author"><a[^>]*>([\s\S]*?)</a>')));
      latest.add(YmMangaLatest(
        id: id,
        title: title,
        cover: absolute(cover),
        cat: cat,
        author: author,
      ));
      if (latest.length >= 10) break;
    }
  }

  return YmMangaHomeFeed(picks: picks, latest: latest);
}

/* ------------------------------- 列表 ------------------------------- */

YmListFeed parseList(String html, [int page = 1]) {
  final items = <YmWork>[];
  for (final m in _all(html, RegExp(r'<tr data-key="(\d+)">([\s\S]*?)</tr>'))) {
    final id = m[1]!;
    final row = m[2]!;
    final cells = _all(row, RegExp(r'<td[^>]*>([\s\S]*?)</td>'))
        .map((x) => x[1] ?? '')
        .toList();
    if (cells.length < 6) continue;
    final title = stripTags(cells[1]);
    final authorAnchor =
        RegExp(r'<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>').firstMatch(cells[2]);
    final cat = stripTags(cells[3]).replaceAll(RegExp(r'^\[|\]$'), '');
    final status = stripTags(cells[4]);
    final license = stripTags(cells[5]);
    final updatedAt = stripTags(cells.length > 6 ? cells[6] : '');
    if (title.isEmpty) continue;
    items.add(YmWork(
      id: id,
      title: title,
      author: authorAnchor != null ? stripTags(authorAnchor[2]!) : stripTags(cells[2]),
      cat: cat,
      status: status,
      license: license,
      updatedAt: updatedAt,
    ));
  }

  final totalRaw = _first(html, RegExp(r'共\s*([\d,]+)\s*篇'));
  final total = int.tryParse(totalRaw.replaceAll(',', '')) ?? 0;
  final lastRaw = _first(html, RegExp(r'data-page="(\d+)"[^>]*>末页'));
  final lastPage = lastRaw.isEmpty ? null : (int.tryParse(lastRaw) ?? 0) + 1;
  final pageNumbers = _all(html, RegExp(r'data-page="(\d+)"'))
      .map((m) => (int.tryParse(m[1] ?? '') ?? 0) + 1)
      .toList();
  final totalPages = lastPage ??
      (pageNumbers.isNotEmpty ? pageNumbers.reduce(math.max) : page);

  return YmListFeed(
    items: items,
    total: total,
    page: page,
    totalPages: totalPages,
  );
}

/* ---------------------------- 详情 + 目录 ---------------------------- */

({String text, String block}) _panelBodyAfter(String html, String marker,
    [int span = 30000]) {
  final at = html.indexOf(marker);
  if (at < 0) return (text: '', block: '');
  final block = html.substring(at, math.min(at + span, html.length));
  final m = RegExp(r'<div class="panel-body">([\s\S]*?)</div>').firstMatch(block);
  return m == null ? (text: '', block: '') : (text: toText(m[1]!), block: m[1]!);
}

({List<YmChapterRef> chapters, int volumes}) _parseToc(String html) {
  final chapters = <YmChapterRef>[];
  var volumes = 0;
  final catAt = html.indexOf('<a name="catalogue"></a>');
  final section = catAt >= 0 ? html.substring(catAt) : html;
  final tocAt = section.indexOf('>目录<');
  final toc = tocAt >= 0 ? section.substring(tocAt) : section;
  final hasVolumes = toc.contains('class="panel panel-info');
  final segments = <({String title, String body})>[];

  if (hasVolumes) {
    final volumeRe = RegExp(
      r'<div class="panel panel-info[^"]*">([\s\S]*?)(?=<div class="panel panel-info|</div>\s*</div>\s*</div>\s*</div>\s*<div class="panel panel-warning">|$)',
    );
    for (final vm in _all(toc, volumeRe)) {
      final seg = vm[1]!;
      final heading = stripTags(_first(seg, RegExp(r'<h4 class="panel-title">([\s\S]*?)</h4>')));
      segments.add((title: heading, body: seg));
    }
    if (segments.isEmpty) {
      final starts = RegExp(r'<h4 class="panel-title">')
          .allMatches(toc)
          .map((m) => m.start)
          .toList();
      for (var i = 0; i < starts.length; i++) {
        final part = toc.substring(
          starts[i],
          i + 1 < starts.length ? starts[i + 1] : toc.length,
        );
        final heading = stripTags(_first(part, RegExp(r'<h4 class="panel-title">([\s\S]*?)</h4>')));
        if (heading.isNotEmpty && RegExp(r'共\s*\d+\s*章').hasMatch(part)) {
          segments.add((title: heading, body: part));
        }
      }
    }
  } else {
    segments.add((title: '', body: toc));
  }

  final seen = <String>{};
  for (final seg in segments) {
    if (seg.title.isNotEmpty) volumes += 1;
    for (final m in _all(
      seg.body,
      RegExp(r'href="/novel/view-chapter\?id=(\d+)"[^>]*>([\s\S]*?)</a>'),
    )) {
      final id = m[1]!;
      if (seen.contains(id)) continue;
      final title = stripTags(m[2]!);
      if (title.isEmpty) continue;
      seen.add(id);
      chapters.add(YmChapterRef(id: id, title: title, volume: seg.title));
    }
  }
  return (chapters: chapters, volumes: volumes);
}

YmNovelDetail parseDetail(String html, [String id = '']) {
  final workAt = html.indexOf('<!-- work -->');
  final head = workAt >= 0
      ? html.substring(workAt, math.min(workAt + 60000, html.length))
      : html;
  final title = stripTags(_first(head, RegExp(r'<h3 class="col-md-12"[^>]*>([\s\S]*?)</h3>')));
  final cover = absolute(_first(head, RegExp(r'<img class="img-responsive"[^>]*src="([^"]+)"')));

  String field(String label) =>
      stripTags(_first(head, RegExp('$label：([^<]*)')));

  final authorAt = html.indexOf('>作者<');
  final authorBlock = authorAt >= 0
      ? html.substring(authorAt, math.min(authorAt + 5000, html.length))
      : head;
  final authorName = stripTags(_first(authorBlock, RegExp(r'<h5[^>]*>([\s\S]*?)</h5>')));

  final tags = <String>[];
  for (final m in _all(head, RegExp(r'<a class="label label-(?:ntype|tag)"[^>]*>([\s\S]*?)</a>'))) {
    final t = stripTags(m[1]!);
    if (t.isNotEmpty && !tags.contains(t)) tags.add(t);
  }

  final intro = _panelBodyAfter(html, '>作品简介<').text;
  final notice = _panelBodyAfter(html, '>作者公告<').text;
  final toc = _parseToc(html);

  return YmNovelDetail(
    id: id.isNotEmpty ? id : workIdFromUrl(_first(head, RegExp(r'href="/novel/(\d+)"'))),
    title: title,
    author: authorName,
    cat: field('作品分类'),
    status: field('作品状态'),
    publishedAt: field('发布时间'),
    updatedAt: field('更新时间'),
    license: field('作品授权'),
    hits: field('点击').isNotEmpty
        ? field('点击')
        : stripTags(_first(head, RegExp(r'点击：([\d,]+)'))),
    favs: field('收藏').isNotEmpty
        ? field('收藏')
        : stripTags(_first(head, RegExp(r'收藏：([\d,]+)'))),
    score: stripTags(_first(head, RegExp(r'<label id="lblRate">([^<]*)</label>'))),
    tags: tags,
    intro: intro,
    notice: notice,
    cover: cover,
    latestChapter: toc.chapters.isEmpty ? '' : toc.chapters.last.title,
    chapters: toc.chapters,
    csrfToken: parseCsrfToken(html),
    favored: parseFavored(html),
  );
}

/* ------------------------------- 正文 ------------------------------- */

YmChapterContent parseChapter(String html, [String id = '']) {
  final sectionAt = html.indexOf('<section class="col-md-9"');
  final section = sectionAt >= 0 ? html.substring(sectionAt) : html;
  final title = stripTags(_first(section, RegExp(r'<h3>([\s\S]*?)</h3>')));
  final author = stripTags(_first(section, RegExp(r'作者：([\s\S]*?)</div>')));
  final words = stripTags(_first(section, RegExp(r'章节字数：([\s\S]*?)</div>')));

  final crumb = RegExp(r'<li><a href="/novel/(\d+)">([\s\S]*?)</a></li>\s*<li class="active">')
      .firstMatch(html);
  final workId = crumb?.group(1) ?? '';
  final workTitle = crumb == null ? '' : stripTags(crumb.group(2)!);

  var prev = '';
  var next = '';

  for (final m in _all(
    section,
    RegExp(r'<a class="btn btn-sm btn-yuri[^"]*" href="/novel/view-chapter\?id=(\d+)"[^>]*>([\s\S]*?)</a>'),
  )) {
    final text = stripTags(m[2]!);
    if (text.contains('上一章')) {
      prev = m[1]!;
    } else if (text.contains('下一章')) {
      next = m[1]!;
    }
  }

  var contentHtml = '';
  final txtAt = section.indexOf('<div id="txt"');
  if (txtAt >= 0) {
    final tm = RegExp(r'<div class="panel-body">([\s\S]*?)</div>')
        .firstMatch(section.substring(txtAt));
    if (tm != null) contentHtml = tm[1]!;
  }
  if (contentHtml.isEmpty) {
    final pm = RegExp(r'<div id="w0-collapse1"[^>]*><div class="panel-body">([\s\S]*?)</div>')
        .firstMatch(section);
    if (pm != null) contentHtml = pm[1]!;
  }

  final paragraphs = <String>[];
  for (var raw in contentHtml.split(RegExp(r'</p>', caseSensitive: false))) {
    raw = raw.replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '');
    final text = toText(raw);
    if (text.isEmpty) continue;
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) paragraphs.add(t);
    }
  }

  return YmChapterContent(
    id: id.isNotEmpty
        ? id
        : chapterIdFromUrl(_first(html, RegExp(r'view-chapter\?id=(\d+)'))),
    title: title,
    workId: workId,
    workTitle: workTitle,
    author: author,
    paragraphs: paragraphs,
    prev: prev,
    next: next,
    words: words.isNotEmpty
        ? words
        : '${paragraphs.join('').replaceAll(RegExp(r'\s'), '').length}',
    csrfToken: parseCsrfToken(html),
  );
}

/* ------------------------------- 排行 ------------------------------- */

YmRankFeed parseRank(String html) {
  final loginRequired = RegExp(r'name="LoginForm\[username\]"').hasMatch(html) &&
      !RegExp(r'class="no\d+"').hasMatch(html);
  final items = <YmRankItem>[];
  for (final m in _all(html, RegExp(r'<tr>([\s\S]*?)</tr>'))) {
    final row = m[1]!;
    final id = _first(row, RegExp(r'href="/(?:novel|manga)/(\d+)"'));
    if (id.isEmpty) continue;
    final cells = _all(row, RegExp(r'<td[^>]*>([\s\S]*?)</td>'))
        .map((x) => x[1] ?? '')
        .toList();
    if (cells.length < 6) continue;
    final title = stripTags(_first(cells[1], RegExp(r'<a[^>]*>([\s\S]*?)</a>')));
    final author = stripTags(_first(cells[2], RegExp(r'<a[^>]*>([\s\S]*?)</a>')));
    final rankRaw = _first(cells[0], RegExp(r'class="no\d+"[^>]*>\s*(\d+)'));
    items.add(YmRankItem(
      id: id,
      rank: int.tryParse(rankRaw) ?? (items.length + 1),
      title: title,
      author: author.isNotEmpty ? author : stripTags(cells[2]),
      cat: stripTags(cells[3]).replaceAll(RegExp(r'^\[|\]$'), ''),
      status: stripTags(cells[4]),
      license: stripTags(cells[5]),
    ));
  }
  return YmRankFeed(items: items, loginRequired: loginRequired);
}

YmSearchFeed parseAdvancedSearch(String html, [int page = 1]) {
  final loginRequired = RegExp(r'name="LoginForm\[username\]"').hasMatch(html) &&
      !RegExp(r'<tr data-key="\d+"').hasMatch(html);
  final items = <YmWork>[];
  for (final m in _all(html, RegExp(r'<tr data-key="(\d+)">([\s\S]*?)</tr>'))) {
    final id = m[1]!;
    final row = m[2]!;
    final cells = _all(row, RegExp(r'<td[^>]*>([\s\S]*?)</td>'))
        .map((x) => x[1] ?? '')
        .toList();
    if (cells.length < 7) continue;
    final title = stripTags(cells[1]);
    if (title.isEmpty) continue;
    items.add(YmWork(
      id: id,
      title: title,
      author: stripTags(cells[2]),
      cat: stripTags(cells[3]).replaceAll(RegExp(r'^\[|\]$'), ''),
      status: stripTags(cells[4]),
      license: stripTags(cells[5]),
      updatedAt: stripTags(cells[6]),
      heat: cells.length > 7
          ? RegExp(r'fa-fire').allMatches(cells[7]).length
          : 0,
    ));
  }

  final totalRaw = _first(html, RegExp(r'共\s*([\d,]+)\s*条'));
  final total = int.tryParse(totalRaw.replaceAll(',', '')) ?? 0;
  const pageSize = 20;
  final totalPages = total > 0
      ? (total / pageSize).ceil()
      : (items.isNotEmpty ? page : 0);
  return YmSearchFeed(
    items: items,
    total: total,
    page: page,
    totalPages: totalPages,
    pageSize: pageSize,
    loginRequired: loginRequired,
  );
}

/* ------------------------------- 账号 ------------------------------- */

const _genericUserText = ['我的空间', '个人中心', '退出', '设置', '我的主页'];

YmMyInfo parseMyPage(String html) {
  final loginRequired = RegExp(r'name="LoginForm\[username\]"').hasMatch(html);
  final loggedIn = !loginRequired;

  var name = '';
  var uid = '';

  final logoutBtn = RegExp(r'class="[^"]*\blogout\b[^"]*"[^>]*>\s*[（(]\s*([^()（）<]{1,24}?)\s*[）)]\s*退出')
      .firstMatch(html);
  if (logoutBtn != null) {
    name = stripTags(logoutBtn.group(1)!).replaceAll(RegExp(r'^@'), '').trim();
  }

  if (name.isEmpty) {
    final m = RegExp(r'class="[^"]*(?:user-?name|nickname|user-?nick)[^"]*"[^>]*>([\s\S]{0,60}?)<',
            caseSensitive: false)
        .firstMatch(html);
    if (m != null) {
      final text = stripTags(m.group(1)!).replaceAll(RegExp(r'^@'), '').trim();
      if (text.isNotEmpty && text.length <= 24) name = text;
    }
  }

  if (name.isEmpty) {
    final nav = _first(html, RegExp(r'(<nav[\s\S]*?</nav>)', caseSensitive: false));
    final scope = nav.isNotEmpty ? nav : html;
    for (final m in _all(
      scope,
      RegExp(r'<a[^>]+href="[^"]*/user/(?:view|space)\?id=(\d+)"[^>]*>([\s\S]{0,80}?)</a>',
          caseSensitive: false),
    )) {
      final text = stripTags(m.group(2)!).replaceAll(RegExp(r'^@'), '').trim();
      if (text.isNotEmpty && text.length <= 24 && !_genericUserText.contains(text)) {
        name = text;
        if (uid.isEmpty) uid = m.group(1)!;
        break;
      }
    }
  }

  if (uid.isEmpty) {
    uid = _first(html, RegExp(r'/user/space\?id=(\d+)'));
  }
  if (uid.isEmpty) {
    uid = _first(html, RegExp(r'/user/view\?id=(\d+)'));
  }

  return YmMyInfo(loggedIn: loggedIn, name: name, uid: uid);
}

/// 取站点 CSRF token（`_csrf-frontend`）。注销表单要靠它。
///
/// 两个来源与 uni 版 `parseCsrfToken` 一致：`<meta name="csrf-token">` 优先，
/// 其次表单里的隐藏 input。站点只给 `_csrf-frontend`，所以按它取。
String parseCsrfToken(String html) {
  final meta = RegExp(r'''<meta[^>]+name=["']csrf-token["'][^>]*>''',
          caseSensitive: false)
      .firstMatch(html);
  if (meta != null) {
    final content =
        RegExp(r'''content=["']([^"']+)["']''', caseSensitive: false)
            .firstMatch(meta.group(0)!);
    if (content != null) return content.group(1)!.trim();
  }
  final input = RegExp(
    r'''name=["']_csrf-frontend["'][^>]*value=["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(html);
  return input != null ? input.group(1)!.trim() : '';
}

/* ------------------------- 漫画详情 / 章节 --------------------------- */

YmMangaDetailResult parseMangaDetail(String html, [String id = '']) {
  final loginRequired = RegExp(r'name="LoginForm\[username\]"').hasMatch(html);

  final title = stripTags(_first(html, RegExp(r'<h3 class="col-md-12"[^>]*>([\s\S]*?)</h3>')));
  final cover = absolute(decodeEntities(_first(
    html,
    RegExp(r'<img class="img-responsive" src="([^"]*/coverm/[^"]+)"'),
  )));

  final meta = <String, String>{};
  for (final m in _all(html, RegExp(r'<p class="col-md-6">\s*([^：:<]{1,8})[：:]\s*([\s\S]*?)</p>'))) {
    final key = stripTags(m[1]!).replaceAll(RegExp(r'\s+'), '');
    final value = stripTags(m[2]!).replaceAll(RegExp(r'^[：:]\s*'), '');
    if (key.isNotEmpty && value.isNotEmpty && !meta.containsKey(key)) {
      meta[key] = value;
    }
  }

  final introBlock = _first(
    html,
    RegExp(r'<div id="w0-collapse1"[^>]*>\s*<div class="panel-body">([\s\S]*?)</div>'),
  );
  final intro = toText(introBlock);

  final chapters = <YmChapterRef>[];
  for (final m in _all(
    html,
    RegExp(r'<div data-key="(\d+)">\s*<div class="col-md-4">\s*<a[^>]+href="[^"]*manga/view-chapter\?id=\d+"[^>]*>([\s\S]*?)</a>'),
  )) {
    chapters.add(YmChapterRef(id: m[1]!, title: stripTags(m[2]!), volume: ''));
  }

  final detail = YmMangaDetail(
    id: id,
    title: title,
    cover: cover,
    author: meta['作者'] ?? '',
    translator: meta['汉化者'] ?? '',
    cat: meta['作品分类'] ?? '',
    status: meta['作品状态'] ?? '',
    license: meta['作品授权'] ?? '',
    region: meta['地区'] ?? '',
    version: meta['版本'] ?? '',
    form: meta['形式'] ?? '',
    publishedAt: meta['发布时间'] ?? '',
    updatedAt: meta['更新时间'] ?? '',
    hits: _first(html, RegExp(r'<p class="clearfix">\s*点击：\s*([\d,]+)')),
    favs: _first(html, RegExp(r'<p class="clearfix">\s*收藏：\s*([\d,]+)')),
    score: _first(html, RegExp(r'id="lblRate">([\d.]+)<')),
    intro: intro,
    chapters: chapters,
    csrfToken: parseCsrfToken(html),
    favored: parseFavored(html),
  );

  return YmMangaDetailResult(detail: detail, loginRequired: loginRequired);
}

YmMangaChapterResult parseMangaChapter(String html, [int page = 1]) {
  final loginRequired = RegExp(r'name="LoginForm\[username\]"').hasMatch(html);

  final heading = stripTags(_first(html, RegExp(r'<h3>([\s\S]*?)</h3>')));
  final rawTitle = heading.isNotEmpty
      ? heading
      : stripTags(_first(html, RegExp(r'<title>([\s\S]*?)</title>')))
          .replaceAll(RegExp(r'\s*-\s*百合会\s*$'), '');

  final rawImage = decodeEntities(_first(html, RegExp(r'<img id="imgPic"[^>]*src="([^"]+)"')));
  final image = rawImage.isEmpty
      ? ''
      : absolute(rawImage).replaceAll(RegExp(r'^http:', caseSensitive: false), 'https:');

  final mark = RegExp(r'addMark\(\s*\d+\s*,\s*(\d+)\s*,\s*(\d+)').firstMatch(html);
  final workId = mark?.group(1) ?? _first(html, RegExp(r'/manga/(\d+)'));
  final chapterId = mark?.group(2) ?? '';
  final nextChapterId = _first(
    html,
    RegExp(r'id="btnNext"[^>]*href="[^"]*manga/view-chapter\?id=(\d+)"'),
  );

  var totalPages = 1;
  for (final m in _all(html, RegExp(r'data-page="(\d+)"'))) {
    totalPages = math.max(totalPages, (int.tryParse(m[1] ?? '') ?? 0) + 1);
  }
  final safePage = page.clamp(1, totalPages);

  return YmMangaChapterResult(
    page: YmMangaPageSample(
      title: rawTitle,
      image: image,
      workId: workId,
      chapterId: chapterId,
      nextChapterId: nextChapterId,
      page: safePage,
      totalPages: totalPages,
      csrfToken: parseCsrfToken(html),
    ),
    loginRequired: loginRequired,
  );
}

/* --------------------------- 漫画列表 / 分类 -------------------------- */

YmMangaListFeed parseMangaList(String html, [int page = 1]) {
  final loginRequired = RegExp(r'name="LoginForm\[username\]"').hasMatch(html);

  final headBlock = _first(html, RegExp(r'<thead>([\s\S]*?)</thead>'));
  final heads = headBlock.isEmpty
      ? <String>[]
      : _all(headBlock, RegExp(r'<th[^>]*>([\s\S]*?)</th>'))
          .map((m) => stripTags(m[1]!))
          .toList();
  int col(String name) => heads.indexOf(name);
  final cTitle = col('漫画名');
  final cAuthor = col('作者');
  final cCat = col('作品分类');
  final cStatus = col('作品状态');
  final cUpdated = col('更新时间');

  final items = <YmManga>[];
  for (final m in _all(html, RegExp(r'<tr data-key="(\d+)">([\s\S]*?)</tr>'))) {
    final id = m[1]!;
    final row = m[2]!;
    final cells = _all(row, RegExp(r'<td[^>]*>([\s\S]*?)</td>'))
        .map((x) => x[1] ?? '')
        .toList();
    String at(int i) => i >= 0 && i < cells.length ? cells[i] : '';
    final title = stripTags(_first(at(cTitle), RegExp(r'<a[^>]*>([\s\S]*?)</a>')));
    final resolved = title.isNotEmpty ? title : stripTags(at(cTitle));
    if (resolved.isEmpty) continue;
    items.add(YmManga(
      id: id,
      title: resolved,
      author: stripTags(at(cAuthor)),
      cat: stripTags(at(cCat)).replaceAll(RegExp(r'^\[|\]$'), ''),
      status: stripTags(at(cStatus)),
      updatedAt: stripTags(at(cUpdated)),
    ));
  }

  final totalRaw = _first(html, RegExp(r'共\s*([\d,]+)\s*[篇条]'));
  final total = int.tryParse(totalRaw.replaceAll(',', '')) ?? items.length;
  final pageSize = html.contains('per-page=50') ? 50 : 20;
  var lastPage = 1;
  for (final m in _all(html, RegExp(r'[?&]page=(\d+)'))) {
    lastPage = math.max(lastPage, int.tryParse(m[1] ?? '') ?? 0);
  }
  final totalPages = math.max(lastPage, (total / pageSize).ceil().clamp(1, 1 << 30));

  return YmMangaListFeed(
    items: items,
    total: total,
    page: page,
    totalPages: totalPages,
    pageSize: pageSize,
    loginRequired: loginRequired,
  );
}

/* ------------------------------ 编辑推荐 ----------------------------- */

YmRcmdsFeed parseRcmds(String html, [int page = 1]) {
  final loginRequired = RegExp(r'name="LoginForm\[username\]"').hasMatch(html);

  final items = <YmRcmdItem>[];
  for (final m in _all(html, RegExp(r'<tr data-key="(\d+)">([\s\S]*?)</tr>'))) {
    final cells = _all(m[2]!, RegExp(r'<td[^>]*>([\s\S]*?)</td>'))
        .map((x) => x[1] ?? '')
        .toList();
    if (cells.length < 4) continue;
    final id = workIdFromUrl(_first(cells[1], RegExp(r'href="([^"]+)"')));
    final title = stripTags(cells[1]);
    if (id.isEmpty || title.isEmpty) continue;
    items.add(YmRcmdItem(
      id: id,
      title: title,
      intro: stripTags(cells[2]),
      createdAt: stripTags(cells[3]),
    ));
  }

  final totalRaw = _first(html, RegExp(r'共\s*([\d,]+)\s*篇'));
  final total = int.tryParse(totalRaw.replaceAll(',', '')) ?? items.length;
  var lastPage = 1;
  for (final m in _all(html, RegExp(r'[?&]page=(\d+)'))) {
    lastPage = math.max(lastPage, int.tryParse(m[1] ?? '') ?? 0);
  }
  final totalPages = math.max(lastPage, (total / 10).ceil().clamp(1, 1 << 30));

  return YmRcmdsFeed(
    items: items,
    total: total,
    page: page,
    totalPages: totalPages,
    pageSize: 10,
    loginRequired: loginRequired,
  );
}

/* ------------------------------ 站内书签 ----------------------------- */

/// 解析 `/my/bookmark`（小说与漫画**混排**；`?type=2|4` 只取一类）。
///
/// 行结构（实测样本）：
///
/// ```html
/// <tr data-key="22592">
///   <td>1</td><td>第1章 一切的开始</td>
///   <td>[原创小说] 最是人间留不住</td><td>千山yuri</td>
///   <td><a href="/novel/view-chapter?id=38822860">▶</a></td>
/// </tr>
/// ```
///
/// ⚠ **空态站点不印表格**（`#w0 > .empty`），所以 items 为空是正常空列表，不是解析失败。
/// 判「空」与「没解析到」只能靠调用方比对 `total`（页脚有「共 N 条」才说明有数据）。
YmBookmarkFeed parseBookmarkList(String html, {int page = 1}) {
  final items = <YmBookmarkItem>[];

  for (final row in _all(html, RegExp(r'<tr[^>]*data-key="(\d+)"[^>]*>([\s\S]*?)</tr>'))) {
    final dataKey = row.group(1) ?? '';
    final body = row.group(2) ?? '';
    final cells = _all(body, RegExp(r'<td[^>]*>([\s\S]*?)</td>')).toList();
    if (cells.length < 5) continue;

    // 末列是播放链接，`&` 在 HTML 里写作 `&amp;`，必须先解码才能抠出 page
    final link = decodeEntities(cells[4].group(1) ?? '');
    final chaptId = _first(link, RegExp(r'[?&]id=(\d+)'));
    if (chaptId.isEmpty) continue; // 没有章节 id 的行打不开，跳过

    final rawWork = stripTags(cells[2].group(1) ?? '').trim();
    final stripped = rawWork.replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), '').trim();

    items.add(YmBookmarkItem(
      dataKey: dataKey,
      chaptId: chaptId,
      chaptTitle: stripTags(cells[1].group(1) ?? '').trim(),
      workTitle: stripped.isEmpty ? rawWork : stripped,
      author: stripTags(cells[3].group(1) ?? '').trim(),
      // 类型按链接路径判，不按作品名的方括号前缀（那是文案不是字段）
      manga: link.contains('/manga/'),
      page: int.tryParse(_first(link, RegExp(r'[?&]page=(\d+)'))) ?? 1,
    ));
  }

  final total = int.tryParse(_first(html, RegExp(r'共\s*(\d+)\s*[条篇]'))) ?? 0;
  return YmBookmarkFeed(items: items, total: total, page: page);
}

/* ------------------------------ 我的收藏 ----------------------------- */

/// 解析 `/my/fav`（**不是 table，是 `list-view` 卡片流**，与 `/my/bookmark` 不同）。
///
/// 卡片结构（实测样本）：
///
/// ```html
/// <div class="thumbnail">
///   <div class="col-md-2"><a href="/novel/264784"><img src="/covern/000/264/784.jpg?=…"></a></div>
///   <div class="col-md-8">
///     <h4><a href="/novel/264784">书名</a></h4>
///     <p>作者：Xmage</p><p>分类：原创小说</p><p>作品状态：连载中</p>
///     <p>更新时间：2024-01-20</p>
///     <p><strong>最近更新</strong> <a href="/novel/view-chapter?id=…">第236章 …</a></p>
///   </div>
/// </div>
/// ```
///
/// ⚠ 三条与书签页的差别，别照抄书签的解析：
/// 1. **有 workId**（书名链接里）⇒ 打开作品不用先换 id，直接进详情；
/// 2. **有封面**，但是相对路径（`/covern/` 小说、`/coverm/` 漫画）⇒ 要 [absolute]；
/// 3. 类型按链接路径判，不按 `分类：` 文案（分类是「原创小说 / 同人」，不含漫画二字）。
///
/// 空态站点同样**不印容器**（`#w0 > .empty`），所以 items 为空是正常空列表；
/// 有无数据只看页脚「共 N 篇」。
YmFavFeed parseFavList(String html, {int page = 1}) {
  final items = <YmFavItem>[];

  // 按卡片切段：每一段里各字段只出现一次，正则不容易串到相邻卡片
  final blocks = html.split(RegExp(r'<div class="thumbnail">'));
  for (var i = 1; i < blocks.length; i++) {
    final block = blocks[i];

    final workUrl = _first(block, RegExp(r'href="(/(?:novel|manga)/\d+)"'));
    final workId = workIdFromUrl(workUrl);
    if (workId.isEmpty) continue; // 拿不到作品 id 的卡片打不开，跳过

    final title = stripTags(
      _first(block, RegExp(r'<h4[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)</a>')),
    );
    if (title.isEmpty) continue;

    items.add(YmFavItem(
      workId: workId,
      title: title,
      author: stripTags(_first(block, RegExp(r'作者：([\s\S]*?)</p>'))),
      manga: workUrl.contains('/manga/'),
      cover: absolute(_first(block, RegExp(r'<img[^>]*src="([^"]+)"')).trim()),
      category: stripTags(_first(block, RegExp(r'分类：([\s\S]*?)</p>'))),
      status: stripTags(_first(block, RegExp(r'作品状态：([\s\S]*?)</p>'))),
      updatedAt: stripTags(_first(block, RegExp(r'更新时间：([\s\S]*?)</p>'))),
      latestChapterId: _first(
        block,
        RegExp(r'最近更新</strong>\s*<a[^>]*href="[^"]*[?&]id=(\d+)"'),
      ),
      latestChapterTitle: stripTags(
        _first(block, RegExp(r'最近更新</strong>\s*<a[^>]*>([\s\S]*?)</a>')),
      ),
    ));
  }

  final total = int.tryParse(_first(html, RegExp(r'共\s*([\d,]+)\s*[条篇]')).replaceAll(',', '')) ?? 0;
  return YmFavFeed(
    items: items,
    total: total,
    page: page,
    csrfToken: parseCsrfToken(html),
  );
}
