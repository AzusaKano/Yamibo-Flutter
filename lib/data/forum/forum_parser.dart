/// 百合会论坛 HTML 解析器（纯函数），与阅读侧 `parser.dart` 完全独立。
///
/// 锚点基于 Discuz 手机模板 `oyeeh_com_baihe_f_x35/touch` 的实际输出。
/// 站点改版集中修这里。
///
/// 解析注意：
/// - 列表行 `li.list` 内部嵌套 `threadlist_foot` 的 `<li>`（阅读/回复计数），
///   所以**不能**用懒匹配 `([\s\S]*?)</li>` 截块，只能按「下一个 `li.list*` 起点」切；
/// - 置顶行在 `li.list_top`，公告行可能没有 tid（链接指向 announcement）。
library;

import 'dart:ui' show TextAlign;

import '../http.dart' show YmHttpError;
import 'forum_models.dart';
import 'forum_user.dart';

const String _site = 'https://bbs.yamibo.com';

// ---------------------------------------------------------------------------
// 论坛首页（index）
// ---------------------------------------------------------------------------

/// 首页解析：公告条 + 分区卡（庙堂 / 江湖 …）。
/// 轮播图不解析（A 屏不做轮播）；「热门讨论」由 api 层另取動漫區列表。
ForumHome parseForumHome(String html) {
  // 公告：<div class="ann-box"> … <ul><li><span><a …>标题</a></span><em>(日期)</em></li>…</ul>
  final annBox = _first(html, RegExp(r'<div class="ann-box">([\s\S]*?)<script')) ?? '';
  final announcements = <String>[];
  if (annBox.isNotEmpty) {
    for (final m in _all(annBox, RegExp(r'<a href="[^"]*"[^>]*>([\s\S]*?)</a>'))) {
      final t = stripTags(m.group(1) ?? '');
      if (t.isNotEmpty) announcements.add(t);
    }
  }

  // 分区：`.subforumshow`（组名）紧跟 `#sub-forum_N`（板块行）。
  // 按出现顺序切片：组名从 h2 取，板块行在 h2 之后、下一组之前的范围内。
  final groupStarts =
      _all(html, RegExp(r'<div class="subforumshow cl"')).toList();
  final cats = <ForumCat>[];
  final nextGroupEnd =
      RegExp(r'<div class="footer').firstMatch(html)?.start ?? html.length;
  for (var i = 0; i < groupStarts.length; i++) {
    final start = groupStarts[i].start;
    final end = i + 1 < groupStarts.length ? groupStarts[i + 1].start : nextGroupEnd;
    final chunk = html.substring(start, end);
    final name = stripTags(_first(chunk, RegExp(r'<h2><a[^>]*>([\s\S]*?)</a>')) ?? '');
    if (name.isEmpty) continue;

    final forums = <ForumBoardRef>[];
    for (final m in _all(chunk, RegExp(r'<a href="forum\.php\?mod=forumdisplay&amp;fid=(\d+)[^"]*" class="murl">([\s\S]*?)</a>'))) {
      final inner = m.group(2)!;
      final todayRaw = _first(inner, RegExp(r'<span class="mnum">今日\s*(\d+)'));
      // 板块名要把「今日 N」角标先剥掉：stripTags 会把 span 折成空格，
      // 不剥的话名字变成「管理版 今日 2」
      final title = stripTags(
        (_first(inner, RegExp(r'<p class="mtit">([\s\S]*?)</p>')) ?? '')
            .replaceAll(RegExp(r'<span class="mnum">[\s\S]*?</span>'), ''),
      );
      forums.add(ForumBoardRef(
        fid: m.group(1)!,
        name: title,
        desc: blockText(_first(inner, RegExp(r'<p class="mtxt">([\s\S]*?)</p>')) ?? ''),
        today: todayRaw == null ? null : int.tryParse(todayRaw),
      ));
    }
    if (forums.isNotEmpty) cats.add(ForumCat(name: name, forums: forums));
  }

  return ForumHome(announcements: announcements, cats: cats);
}

// ---------------------------------------------------------------------------
// 帖子页（viewthread）
// ---------------------------------------------------------------------------

/// 楼层起点：`<div class="plc cl" id="pidNNN">`。
/// 点评块的 `plc p0 cl id="commentdetail…"` 不是这个形状，不会误入。
final _floorStartRe = RegExp(r'<div class="plc cl" id="pid(\d+)">');

/// 正文起点：`<div class="message">`。站点当前不带属性，留 `[^>]*` 容错。
final _messageOpenRe = RegExp(r'<div class="message"[^>]*>');

/// 站方「热点推荐」解析（PC 版论坛首页的 DIY 模块，手机模板不印）：
/// 管理员后台手选的全站热点，条目形状：
/// `<div class="tit"><h2>热点推荐</h2></div>` 后跟
/// `<div class="module cl xl xl1"><ul><li><em>日期</em><a href="thread-N-1-1.html"
/// title="完整标题">显示文本（可能截断、可能带高亮 font）</a></li>…</ul>`。
/// 标题优先取 `title` 属性的完整版（显示文本是站点截断的）；没有就退显示文本。
/// 块是后台配置的——改名/清空/挪位时锚不到 → 返回空列表，调用方安静隐藏
///（不编、不报错；锚点按标题文案钉，站方改文案即视为「本期没有热点推荐」）。
List<ForumThreadSummary> parseForumHot(String html) {
  final headAt = html.indexOf('>热点推荐<');
  if (headAt < 0) return const <ForumThreadSummary>[];
  final moduleAt = html.indexOf('<div class="module cl xl xl1">', headAt);
  if (moduleAt < 0) return const <ForumThreadSummary>[];
  final ulAt = html.indexOf('<ul>', moduleAt);
  final ulEnd = html.indexOf('</ul>', moduleAt);
  if (ulAt < 0 || ulEnd < 0 || ulEnd < ulAt) return const <ForumThreadSummary>[];
  final chunk = html.substring(ulAt, ulEnd);

  final out = <ForumThreadSummary>[];
  final liRe = RegExp(r'<li><em>([^<]*)</em>\s*<a href="([^"]+)"([^>]*)>([\s\S]*?)</a></li>');
  for (final m in liRe.allMatches(chunk)) {
    final href = m.group(2)!;
    final tid = RegExp(r'thread-(\d+)-').firstMatch(href)?.group(1) ??
        RegExp(r'[?&]tid=(\d+)').firstMatch(href)?.group(1);
    if (tid == null || tid.isEmpty) continue;
    final attrs = m.group(3)!;
    final fullTitle =
        _first(attrs, RegExp(r'title="([^"]*)"')) ?? stripTags(m.group(4)!);
    final title = decodeEntities(fullTitle).trim();
    if (title.isEmpty) continue;
    out.add(ForumThreadSummary(tid: tid, title: title, time: m.group(1)!.trim()));
  }
  return out;
}

/// 帖子页解析。楼层正文切片成块（段落 + 引用，段内混链接片段，见 parseForumBlocks）；
/// 图片提取地址（表情图不收）；点评 / 评分摘要 / 首楼投票按样本锚点取，
/// 拿不到就空——不编。
ForumThreadPage parseThreadPage(String html, {required String tid, int page = 1}) {
  // 标题块：`<div class="view_tit"><em>[杂谈]</em>标题</div>`
  final titRaw = _first(html, RegExp(r'<div class="view_tit">([\s\S]*?)</div>')) ?? '';
  final tag = stripTags(_first(titRaw, RegExp(r'<em>([\s\S]*?)</em>')) ?? '')
      .replaceAll(RegExp(r'^\[|\]$'), '');
  final title = stripTags(titRaw.replaceAll(RegExp(r'<em>[\s\S]*?</em>'), ''));

  // 统计：首楼作者行 `<i class="dm-eye"></i><em>34719</em><i class="dm-chat-s"></i><em>42</em>`
  final views = int.tryParse(_first(html, RegExp(r'dm-eye"></i>\s*<em>(\d+)')) ?? '') ?? 0;
  final repliesRaw = int.tryParse(_first(html, RegExp(r'dm-chat-s"></i>\s*<em>(\d+)')) ?? '');
  final replies = repliesRaw ??
      int.tryParse(_first(html, RegExp(r'全部回复<em>(\d+)</em>')) ?? '') ??
      0;

  final floorStarts = _all(html, _floorStartRe).toList();
  // 楼层区的结束锚点：分页条（没有分页的末页退到回复条）
  final endCandidates = <int>[
    _pgRe.firstMatch(html)?.start ?? html.length,
    RegExp(r'<div class="foot foot_reply').firstMatch(html)?.start ?? html.length,
  ];
  final floorsEnd = endCandidates.reduce((a, b) => a < b ? a : b);

  final posts = <ForumPost>[];
  // 目录只看首楼（作者把 findpost 清单写在一楼 message 里）；二楼及以后不收。
  final toc = <ForumTocEntry>[];
  for (var i = 0; i < floorStarts.length; i++) {
    final start = floorStarts[i].start;
    final end = i + 1 < floorStarts.length ? floorStarts[i + 1].start : floorsEnd;
    if (end <= start) continue;
    final p = _parseFloor(
      html.substring(start, end),
      pid: floorStarts[i].group(1)!,
      tocOut: i == 0 ? toc : null,
    );
    if (p != null) posts.add(p);
  }

  return ForumThreadPage(
    tid: tid,
    title: title,
    tag: tag,
    boardName: _boardName(html),
    views: views,
    replies: replies,
    posts: _resolveSamePageQuotes(posts),
    page: page,
    totalPages: _threadTotalPages(html, posts.isNotEmpty),
    toc: toc,
    fid: _threadFid(html),
  );
}

/// 帖页所属板块号（回帖表单 URL 里的 `fid`，0.1.38 新造，此前没解析过）。
///
/// 站点把「发表回复」链接印在每页顶部，**游客态帖页也带**：
/// `<a href="forum.php?mod=post&action=reply&fid=16&tid=503337&reppost=…&page=1&mobile=2">`。
/// 6 个本地实抓样本全部命中（503337=16 / 506380=33 / 514009=33 / 556336=5 /
/// 568572=5 / 535389=370），所以既不用额外请求、也不用猜板块号。
///
/// 取法：先找含 `action=reply` 的 href，再从**那一串**里取 `fid=`（参数顺序变了也不怕）。
/// 取不到给空串（回帖表单页照样能开，只是不带 fid 参数）。
String _threadFid(String html) {
  for (final m in RegExp(r'<a\s[^>]*?href="([^"]*action=reply[^"]*)"',
          caseSensitive: false)
      .allMatches(html)) {
    final fid =
        RegExp(r'(?:[?&]|&amp;)fid=(\d+)').firstMatch(m.group(1)!)?.group(1);
    if (fid != null && fid.isNotEmpty) return fid;
  }
  return '';
}

/// 首楼目录提取：message HTML 里 `goto=findpost` 锚点的顺序表。
///
/// 口径（2026-11-19 本地样本实测 577729=8 / 572667=76 / 568841=133）：
/// - 条目身份 = href 里的 pid（`ptid=` 是帖子 id，不能用）；
/// - 锚文本原样保留（带序号前缀不动），空锚文本丢弃（图片链接之类）；
/// - **不按标题筛**：番外 / 人设 / 设定整理都是作者列进来的阅读内容；
/// - 同一 pid 出现多次也原样保留（568841 首条「最新一话跳转」与末章同 pid，
///   那是作者自己的导航条目，去重会少一条、与网站目录对不上）。
List<ForumTocEntry> parseForumToc(String messageHtml) {
  final out = <ForumTocEntry>[];
  for (final m in _all(
    messageHtml,
    RegExp(r'<a\s[^>]*?href="([^"]+)"[^>]*>([\s\S]*?)</a>',
        caseSensitive: false),
  )) {
    final href = decodeEntities(m.group(1)!);
    if (!href.contains('goto=findpost')) continue;
    final pid = RegExp(r'[?&]pid=(\d+)').firstMatch(href)?.group(1) ?? '';
    if (pid.isEmpty) continue;
    final title = stripTags(m.group(2)!);
    if (title.isEmpty) continue;
    out.add(ForumTocEntry(pid: pid, title: title));
  }
  return out;
}

/// 帖子页总页数：分页条 `共 N 页` 只在**多页**帖出现（0.1.22 实测：单页帖
/// 连分页条都没有，直接解析是 0）——没有分页条但有楼层 = 明确的单页帖，
/// 返回 1，别给「未知」当（否则加载更多按钮会挂在单页帖上）。
/// 没有楼层（游客锁 / 消息页）维持 0 = 未知，不给「共 1 页」的假承诺。
int _threadTotalPages(String html, bool hasPosts) {
  final n = _totalPages(html);
  if (n > 0) return n;
  return hasPosts ? 1 : 0;
}

/// 同页引用补全（0.1.22 真机反馈：4 楼引用 3 楼这类引用头不可点）。
///
/// 站点对**同页引用不生成 findpost 链接**（网页上同样没有点击入口，实抓核实），
/// 引用头只剩「作者 发表于 时间」——拿这对信息在本页楼层里做唯一匹配补 pid：
/// 恰好一个楼匹配才补（确定性，不是猜）；对不上 / 多个命中 / 字段缺都维持不可点。
/// 匹配用站点原文时间原样比对，相对时间（「昨天 20:15」这类）天然对不上就放弃。
List<ForumPost> _resolveSamePageQuotes(List<ForumPost> posts) {
  final pidByKey = <String, String>{};
  for (final p in posts) {
    if (p.author.isEmpty || p.time.isEmpty) continue;
    final key = '${p.author}\u0000${p.time}';
    // 同作者同分钟发了多条：歧义，宁可不可点也不瞎跳
    pidByKey[key] = pidByKey.containsKey(key) ? '' : p.pid;
  }
  final out = <ForumPost>[];
  for (final p in posts) {
    var changed = false;
    final blocks = <ForumBlock>[];
    for (final b in p.blocks) {
      if (b is ForumQuoteBlock &&
          b.quote.pid.isEmpty &&
          b.quote.author.isNotEmpty &&
          b.quote.time.isNotEmpty) {
        final pid = pidByKey['${b.quote.author}\u0000${b.quote.time}'] ?? '';
        if (pid.isNotEmpty) {
          blocks.add(ForumQuoteBlock(ForumQuote(
            author: b.quote.author,
            time: b.quote.time,
            text: b.quote.text,
            pid: pid,
          )));
          changed = true;
          continue;
        }
      }
      blocks.add(b);
    }
    out.add(changed ? _postWithBlocks(p, blocks) : p);
  }
  return out;
}

ForumPost _postWithBlocks(ForumPost p, List<ForumBlock> blocks) => ForumPost(
      pid: p.pid,
      floor: p.floor,
      author: p.author,
      authorUid: p.authorUid,
      time: p.time,
      blocks: blocks,
      images: p.images,
      comments: p.comments,
      rate: p.rate,
      poll: p.poll,
    );

/// 取 [html] 里 [from] 之后、最早命中任一锚点前的截段。
String _until(String html, int from, List<RegExp> anchors) {
  var end = html.length;
  for (final re in anchors) {
    final m = re.firstMatch(html.substring(from));
    if (m != null && from + m.start < end) end = from + m.start;
  }
  return end > from ? html.substring(from, end) : '';
}

ForumPost? _parseFloor(String block, {required String pid, List<ForumTocEntry>? tocOut}) {
  // 楼层号：`1<sup>#</sup>`
  final floor = int.tryParse(_first(block, RegExp(r'(\d+)\s*<sup>#</sup>')) ?? '');
  if (floor == null) return null;

  final authorM =
      RegExp(r'''<span class="z">\s*<a href="home\.php\?mod=space&amp;uid=(\d+)[^"]*">([\s\S]*?)</a>''')
          .firstMatch(block);

  // 时间行：mtime li，先剥掉统计 span 再转文本
  final mtimeLi = _first(block, RegExp(r'<li class="mtime">([\s\S]*?)</li>')) ?? '';
  final time = stripTags(mtimeLi.replaceAll(RegExp(r'<span class="y">[\s\S]*?</span>'), ''));

  // 正文：message 起点到「回复按钮 / 点评区 / 评分标题 / 评分表」最早的一个。
  // 登录态楼层会在 message 收口之后、点评区之前插
  // `<div class="replybtn"><a>回复</a></div>`（点了楼层才显示，但节点一直在
  // HTML 里）——必须把它当成正文终点，否则按钮文案会落进正文末尾。
  // 注意：不能改用 message 自己的 `</div>` 收口——站点有些楼层把图片列表
  // （`ul.img_one`）放在 message 收口**之后**、点评区之前，按收口截会丢图。
  var message = '';
  final msgOpen = _messageOpenRe.firstMatch(block);
  if (msgOpen != null) {
    message = _until(block, msgOpen.start, [
      RegExp(r'<div id="replybtn_'),
      RegExp(r'<div class="replybtn'),
      RegExp(r'<div id="comment_'),
      RegExp(r'<h3 class="psth'),
      RegExp(r'<div id="ratelog_'),
      RegExp(r'<div class="threadlist_foot'),
    ]).replaceFirst(_messageOpenRe, '');
  }

  // 投票块藏在首楼 message 里，先摘出来再转正文
  ForumPoll? poll;
  final pollM =
      RegExp(r'<div class="poll cl">[\s\S]*?</form>\s*</div>').firstMatch(message);
  var bodyHtml = message;
  if (pollM != null) {
    final pollHtml = pollM.group(0)!;
    bodyHtml = bodyHtml.replaceFirst(pollHtml, '');
    poll = _parsePoll(pollHtml);
  }

  // 目录只认首楼（floor == 1）：翻到第 2 页时该页第一块是 21 楼，
  // 读者回复里的 findpost 链接不能当目录。
  if (tocOut != null && floor == 1) {
    tocOut.addAll(parseForumToc(stripJammer(bodyHtml)));
  }

  // 反采集干扰码（jammer）混在正文换行里，先剥干净再做富文本切片
  //（0.1.22 口径：切片必须发生在 stripJammer 之后，否则隐藏文字会混进片段）
  bodyHtml = stripJammer(bodyHtml);

  final blocks = parseForumBlocks(bodyHtml);

  // 正文图：排除表情（smilieid）与头像区
  final images = <String>[];
  for (final m in _all(bodyHtml, RegExp(r'<img[^>]*>'))) {
    final tag = m.group(0)!;
    if (tag.contains('smilieid')) continue;
    final src = _first(tag, RegExp(r'''src="([^"]+)"'''));
    if (src == null || src.isEmpty) continue;
    final abs = absolute(src);
    if (abs.isNotEmpty && !images.contains(abs)) images.add(abs);
  }

  // 点评区：comment_PID 起，到 评分标题 / 评分表 前
  final comments = <ForumComment>[];
  final cmAt = block.indexOf('<div id="comment_$pid">');
  if (cmAt >= 0) {
    final cmChunk = _until(block, cmAt, [
      RegExp(r'<h3 class="psth[^>]*>[\s\S]{0,40}评分</h3>'),
      RegExp(r'<div id="ratelog_'),
      RegExp(r'<div class="threadlist_foot'),
    ]);
    // 点评条起点切片（commentdetail 内部有嵌套 div，不能懒匹配）
    final starts = _all(cmChunk, RegExp(r'<div class="plc p0 cl" id="commentdetail')).toList();
    for (var i = 0; i < starts.length; i++) {
      final from = starts[i].start;
      final to = i + 1 < starts.length ? starts[i + 1].start : cmChunk.length;
      final row = cmChunk.substring(from, to);
      final name = stripTags(_first(row, RegExp(r'''<span class="z">\s*<a[^>]*>([\s\S]*?)</a>''')) ?? '');
      final cTime = stripTags(_first(row, RegExp(r'发表于\s*([\d\- :]+)')) ?? '');
      final text = stripTags(_first(row, RegExp(r'<li class="mtxt[^>]*>([\s\S]*?)</li>')) ?? '');
      if (name.isNotEmpty || text.isNotEmpty) {
        comments.add(ForumComment(author: name, time: cTime, text: text));
      }
    }
  }

  return ForumPost(
    pid: pid,
    floor: floor,
    author: stripTags(authorM?.group(2) ?? ''),
    authorUid: authorM?.group(1) ?? '',
    time: time,
    blocks: blocks,
    images: images,
    comments: comments,
    rate: _parseRate(block),
    poll: poll,
  );
}

ForumPoll? _parsePoll(String pollHtml) {
  final texts = _all(pollHtml, RegExp(r'<div class="poll_txt">([\s\S]*?)</div>'))
      .map((m) => stripTags(m.group(1) ?? ''))
      .where((t) => t.isNotEmpty)
      .toList();
  final options = <String>[];
  for (final m in _all(pollHtml, RegExp(r'<label for="option_\d+">([\s\S]*?)</label>'))) {
    // 站点原文是「1.赤座灯里」，剥掉序号前缀，名字留原文
    final raw = stripTags(m.group(1) ?? '').replaceFirst(RegExp(r'^\d+\.'), '');
    if (raw.isNotEmpty) options.add(raw);
  }
  if (texts.isEmpty && options.isEmpty) return null;
  return ForumPoll(
    info: texts.isNotEmpty ? texts.first : '',
    end: texts.length > 1 ? texts[1] : '',
    options: options,
    guestNote: stripTags(_first(pollHtml, RegExp(r'<span class="xi1">([\s\S]*?)</span>')) ?? ''),
  );
}

ForumRate? _parseRate(String block) {
  final at = block.indexOf('<div id="ratelog_');
  if (at < 0) return null;
  final chunk = _until(block, at, [
    RegExp(r'<div class="threadlist_foot'),
    RegExp(r'<div class="discuz_x'),
  ]);
  final people = int.tryParse(
          _first(chunk, RegExp(r'参与人数\s*<span class="xi1">(\d+)')) ?? '') ??
      0;
  final score = int.tryParse(
          _first(chunk, RegExp(r'积分\s*<i><span class="xi1">\+(\d+)')) ?? '') ??
      0;
  final items = <ForumRateItem>[];
  for (final m in _all(chunk, RegExp(r'<li class="flex-box mli p0">([\s\S]*?)</li>'))) {
    final row = m.group(1)!;
    // 表头行（参与人数 / 积分 / 理由）也带 `.z a`（查看全部评分的 dialog 链接），按字面排除
    if (row.contains('参与人数')) continue;
    final name = _first(row, RegExp(r'''<span class="z"><a[^>]*>([\s\S]*?)</a>'''));
    if (name == null) continue; // 尾行「查看全部评分」没有名字链接
    final delta = int.tryParse(_first(row, RegExp(r'xi1 xw1">\s*\+\s*(\d+)')) ?? '') ?? 0;
    // 理由：flex-3 档，除表头外只在评分明细行出现
    final reason = stripTags(_first(row, RegExp(r'<div class="flex-3[^"]*">([\s\S]*?)</div>')) ?? '');
    items.add(ForumRateItem(name: stripTags(name), delta: delta, reason: reason));
  }
  if (people == 0 && items.isEmpty) return null;
  return ForumRate(people: people, score: score, items: items);
}

final _entityRe = RegExp(r'&(#x?[0-9a-f]+|[a-z][a-z0-9]+);', caseSensitive: false);

const Map<String, String> _namedEntities = {
  'nbsp': ' ',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'hellip': '…',
  'mdash': '—',
  'middot': '·',
  'times': '×',
  'raquo': '»',
  'copy': '©',
};

String decodeEntities(String input) {
  return input.replaceAllMapped(_entityRe, (m) {
    final ent = m.group(1)!;
    if (ent.startsWith('#')) {
      final hex = ent.length > 1 && (ent[1] == 'x' || ent[1] == 'X');
      final code = int.tryParse(ent.substring(2), radix: hex ? 16 : 10);
      if (code != null && code >= 0x20) return String.fromCharCode(code);
      return m.group(0)!;
    }
    return _namedEntities[ent.toLowerCase()] ?? m.group(0)!;
  });
}

/// 标签内文本 → 一行纯文本（换行折空格）。
String stripTags(String input) {
  return decodeEntities(input.replaceAll(RegExp(r'<[^>]*>'), ' '))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// 剥站点反采集干扰码（Discuz jammer，真机乱码实证 2026-11-15）：
/// 开干扰码的版块（貼圖區/文學區这类）会在正文**每个换行处**追加一段随机串，
/// 两种形状随机二选一——`<font class="jammer">随机串</font>` 与
/// `<span style="display:none">随机串</span>`（function_discuzcode.php:558/308，
/// GitHub DiscuzX 源码实抓核实；随机串 = 5~15 个 chr(32-59)+空格+chr(63-126)）。
/// 浏览器靠 CSS 藏掉它，App 解析器不认样式，把随机串当正文 → 真机乱码。
/// 形状按核心源码钉死（站点用原版行为，无定制痕迹）；正文转文本前调用。
String stripJammer(String html) {
  return html
      .replaceAll(RegExp(r'<font class="jammer">[\s\S]*?</font>'), '')
      .replaceAll(RegExp(r'<span style="display:\s*none">[\s\S]*?</span>'), '');
}

// ---------------------------------------------------------------------------
// 正文富文本切片（0.1.35 · 第十期）：块级结构 + 内联样式栈。
//
// 切片顺序口径不变：jammer 剥离 → poll 摘出 → 块切分（调用方保证）。
// 块级锚点同起点优先级：附件 `ul.post_attlist` > 折叠块 > 引用 > 图 > 分割线；
// 附件 `<ul>` 的 class 里带 `quote`，必须先于引用起点正则识别，否则会被引用吞掉。
// ---------------------------------------------------------------------------

/// 引用块起点：`<div class="quote…">`。
final _quoteStartRe = RegExp(r'<div class="quote[^"]*">', caseSensitive: false);

/// 引用块终点：`</blockquote></div>`（站点形状固定，实抓核实）。
final _quoteEndRe = RegExp(r'</blockquote>\s*</div>', caseSensitive: false);

/// 段落切分锚点：`<br>` 与 `</p>`（与 blockText 的分段口径一致）。
final _paraBreakRe = RegExp(r'<br\s*/?>|</p>', caseSensitive: false);

/// 链接锚点。链接里套 font 等标签的（实抓就有 `<font color="#999999">` 包文本）
/// 由 [_inlineText] 剥成纯文本。
final _linkRe = RegExp(
  r'<a\s[^>]*?href="([^"]+)"[^>]*>([\s\S]*?)</a>',
  caseSensitive: false,
);

/// 附件列表起点（class 里带 `quote`，必须先于引用识别）。
final _attachStartRe =
    RegExp(r'<ul[^>]*\bclass="[^"]*post_attlist[^"]*"[^>]*>', caseSensitive: false);

/// 折叠块：起点 / 标题 / 内容 / 收尾「收起」。
final _collapseStartRe = RegExp(r'<div class="showcollapse_box">', caseSensitive: false);
final _collapseTitleRe =
    RegExp(r'<div class="showcollapse_title"[^>]*>([\s\S]*?)</div>', caseSensitive: false);
final _collapseContentRe =
    RegExp(r'^\s*<div class="showcollapse_content">', caseSensitive: false);
final _collapseGatherRe =
    RegExp(r'<div class="showcollapse_gather"[^>]*>[\s\S]*?</div>', caseSensitive: false);

/// 分割线 / 正文图标签。
final _hrRe = RegExp(r'<hr\b[^>]*>', caseSensitive: false);
final _imgTagRe = RegExp(r'<img\b[^>]*>', caseSensitive: false);

/// 段落对齐包裹：只认 center / left / right（站点 `<center>` 样本 0 处，不做）。
final _alignDivRe =
    RegExp(r'<div\s+align="(center|left|right)"[^>]*>|</div>', caseSensitive: false);

/// 内联标签：链接开 / 闭、样式开关（strong/b、em/i、u、strike/s、font）。
final _inlineTagRe = RegExp(
  r'<a\s[^>]*?href="(?<href>[^"]+)"[^>]*?(?<selfclose>/?)>'
  r'|</a\s*>'
  r'|<(?<open>strong|b|em|i|u|strike|s|font)\b(?<attrs>[^>]*)>'
  r'|</(?<close>strong|b|em|i|u|strike|s|font)\s*>',
  caseSensitive: false,
);

/// 块级锚点种类。
enum _BlockKind { attachment, collapse, quote, image, divider }

/// 一次块级扫描命中的锚点：[start] / [end] 是 bodyHtml 里的绝对下标。
class _BlockAnchor {
  _BlockAnchor(
    this.kind,
    this.start,
    this.end, {
    this.html = '',
    this.title = '',
    this.image,
  });

  final _BlockKind kind;
  final int start;
  final int end;

  /// 附件列表 HTML / 折叠块内容 HTML。
  final String html;
  final String title;
  final ForumImageBlock? image;
}

/// 内联样式栈的一帧：链接帧带 [href]，其余只带样式位。
class _StyleFrame {
  const _StyleFrame(this.kind, this.style, {this.href});

  final String kind;
  final ForumInlineStyle style;
  final String? href;
}

/// bodyHtml → 正文块列表（在 stripJammer 之后的干净 HTML 上调用）。
///
/// 引用块沿用 0.1.22 口径：嵌套引用按深度配对、内层拍平进外层文本，不递归、不丢字。
/// 0.1.35 新增块：正文图（原位）、分割线、折叠块（可递归）、附件列表。
List<ForumBlock> parseForumBlocks(String html) =>
    _parseBlocks(html, depth: 0, seenImages: <String>{});

List<ForumBlock> _parseBlocks(
  String html, {
  required int depth,
  required Set<String> seenImages,
}) {
  final blocks = <ForumBlock>[];
  var i = 0;
  while (i < html.length) {
    final a = _nextAnchor(html, i, seenImages);
    if (a == null) {
      blocks.addAll(_paraBlocks(html.substring(i)));
      break;
    }
    if (a.start > i) blocks.addAll(_paraBlocks(html.substring(i, a.start)));
    // 保护：锚点没前进就跳过，绝不死循环
    if (a.end <= a.start) {
      i = a.start + 1;
      continue;
    }
    switch (a.kind) {
      case _BlockKind.attachment:
        final att = _parseAttachments(a.html);
        if (att != null) blocks.add(att);
      case _BlockKind.collapse:
        blocks.add(ForumCollapseBlock(
          title: a.title,
          blocks: _parseBlocks(
            a.html,
            depth: depth + 1,
            seenImages: seenImages,
          ),
        ));
      case _BlockKind.quote:
        final quote = _parseQuote(html.substring(a.start, a.end));
        if (quote != null) blocks.add(ForumQuoteBlock(quote));
      case _BlockKind.image:
        seenImages.add(a.image!.url);
        blocks.add(a.image!);
      case _BlockKind.divider:
        blocks.add(const ForumDividerBlock());
    }
    i = a.end;
  }
  return blocks;
}

/// 找 [from] 之后最近的一个块级锚点（同起点按「附件 > 折叠 > 引用 > 图 > 分割线」）。
/// 图片去重只看 [seenImages] 不写入——本轮没被选中的图下一轮还要能命中。
_BlockAnchor? _nextAnchor(String html, int from, Set<String> seenImages) {
  _BlockAnchor? best;
  void take(_BlockAnchor a) {
    if (best == null || a.start < best!.start) best = a;
  }

  // 1) 附件列表
  final am = _attachStartRe.firstMatch(html.substring(from));
  if (am != null) {
    final start = from + am.start;
    final close = html.indexOf('</ul>', from + am.end);
    final end = close < 0 ? html.length : close + 5;
    take(_BlockAnchor(_BlockKind.attachment, start, end,
        html: html.substring(start, end)));
  }

  // 2) 折叠块（showcollapse_box → title + content，内容递归解析）
  final cm = _collapseStartRe.firstMatch(html.substring(from));
  if (cm != null) {
    final start = from + cm.start;
    var bodyStart = from + cm.end;
    final titleM = _collapseTitleRe.firstMatch(html.substring(bodyStart));
    if (titleM != null) {
      final title = stripTags(titleM.group(1)!);
      bodyStart += titleM.end;
      final contentTag = _collapseContentRe.firstMatch(html.substring(bodyStart));
      if (contentTag != null) {
        final contentBegin = bodyStart + contentTag.end;
        final contentEnd = _matchingDivEnd(html, contentBegin);
        if (contentEnd != null) {
          final content = html
              .substring(contentBegin, contentEnd)
              .replaceAll(_collapseGatherRe, '');
          var end = contentEnd + 6;
          final boxClose = RegExp(r'^\s*</div>').firstMatch(html.substring(end));
          if (boxClose != null) end += boxClose.end;
          take(_BlockAnchor(_BlockKind.collapse, start, end,
              html: content, title: title));
        }
      }
    }
  }

  // 3) 引用块（沿用 0.1.22 的深度配对）
  final qm = _quoteStartRe.firstMatch(html.substring(from));
  if (qm != null) {
    final qStart = from + qm.start;
    var depth = 1;
    var j = from + qm.end;
    int? qEnd;
    while (j < html.length) {
      final rest = html.substring(j);
      final s = _quoteStartRe.firstMatch(rest);
      final e = _quoteEndRe.firstMatch(rest);
      if (e == null) break;
      if (s != null && s.start < e.start) {
        depth++;
        j += s.end;
        continue;
      }
      depth--;
      j += e.end;
      if (depth == 0) {
        qEnd = j;
        break;
      }
    }
    if (qEnd != null) take(_BlockAnchor(_BlockKind.quote, qStart, qEnd));
  }

  // 4) 正文图（排除表情 smilieid；同 URL 去重；包图取 a.orange 的原图地址）
  var imgFrom = from;
  while (true) {
    final im = _imgTagRe.firstMatch(html.substring(imgFrom));
    if (im == null) break;
    final start = imgFrom + im.start;
    final end = imgFrom + im.end;
    final tag = im.group(0)!;
    imgFrom = end;
    if (tag.contains('smilieid')) continue;
    final src = _first(tag, RegExp(r'src="([^"]+)"'));
    if (src == null || src.isEmpty) continue;
    final url = absolute(decodeEntities(src));
    if (url.isEmpty || seenImages.contains(url)) continue;
    final caption =
        decodeEntities(_first(tag, RegExp(r'alt="([^"]*)"')) ?? '').trim();
    take(_BlockAnchor(_BlockKind.image, start, end,
        image: ForumImageBlock(
          url: url,
          originalUrl: _originalImageUrl(html, start),
          caption: caption,
        )));
    break;
  }

  // 5) 分割线
  final hm = _hrRe.firstMatch(html.substring(from));
  if (hm != null) take(_BlockAnchor(_BlockKind.divider, from + hm.start, from + hm.end));

  return best;
}

/// 包图原图：图片前紧邻 `<a href="…" class="orange" />`（站点自闭合锚点）。
String _originalImageUrl(String html, int imgStart) {
  final from = imgStart > 400 ? imgStart - 400 : 0;
  final pre = html.substring(from, imgStart);
  final m = RegExp(
    r'<a\s[^>]*?href="([^"]+)"[^>]*?class="[^"]*orange[^"]*"[^>]*>\s*$',
    caseSensitive: false,
  ).firstMatch(pre);
  if (m == null) return '';
  return absolute(decodeEntities(m.group(1)!));
}

/// 附件列表 `ul.post_attlist` → [ForumAttachmentBlock]（取不到条目返回 null，不编）。
ForumAttachmentBlock? _parseAttachments(String ulHtml) {
  final items = <ForumAttachment>[];
  for (final m in RegExp(r'<li[^>]*>([\s\S]*?)</li>', caseSensitive: false)
      .allMatches(ulHtml)) {
    final row = m.group(1)!;
    final name = stripTags(_first(
          row,
          RegExp(r'<span class="link f_b">([\s\S]*?)</span>', caseSensitive: false),
        ) ??
        '');
    if (name.isEmpty) continue;
    final hrefRaw = _first(
        row, RegExp(r'<a\s[^>]*?href="([^"]+)"', caseSensitive: false));
    final href = hrefRaw == null ? '' : absolute(decodeEntities(hrefRaw));
    final ps = _all(row, RegExp(r'<p class="pl5 f_9">([\s\S]*?)</p>', caseSensitive: false))
        .map((e) => stripTags(e.group(1)!))
        .toList();
    var size = '';
    for (final p in ps) {
      if (p.contains('下载') || RegExp(r'\d\s*(?:B|KB|MB|GB)\b').hasMatch(p)) {
        size = p.split(',').first.trim();
        break;
      }
    }
    if (size.isEmpty && ps.length > 1) size = ps.last.split(',').first.trim();
    items.add(ForumAttachment(name: name, size: size, href: href));
  }
  return items.isEmpty ? null : ForumAttachmentBlock(items);
}

/// [from] 之后那个 `</div>` 的起点（[from] 处已有一个打开的 div，深度从 1 起算）。
int? _matchingDivEnd(String html, int from) {
  var depth = 1;
  var i = from;
  while (i < html.length) {
    final open = html.indexOf('<div', i);
    final close = html.indexOf('</div>', i);
    if (close < 0) return null;
    if (open >= 0 && open < close) {
      depth++;
      i = open + 4;
      continue;
    }
    depth--;
    if (depth == 0) return close;
    i = close + 6;
  }
  return null;
}

/// 文字 HTML → 段落块。段落里没有任何内容就丢弃（不产空段）。
/// `<div align="center">` 包裹的段落给 `align: center`（样本 8 处）。
List<ForumBlock> _paraBlocks(String html) {
  final blocks = <ForumBlock>[];
  if (html.isEmpty) return blocks;
  final alignStack = <TextAlign>[];

  void emit(String chunk) {
    if (chunk.isEmpty) return;
    final align = alignStack.isEmpty ? TextAlign.start : alignStack.last;
    for (final seg in chunk.split(_paraBreakRe)) {
      final inlines = parseForumInlines(seg);
      if (inlines.isNotEmpty) blocks.add(ForumParaBlock(inlines, align: align));
    }
  }

  var cursor = 0;
  for (final m in _alignDivRe.allMatches(html)) {
    emit(html.substring(cursor, m.start));
    final tag = m.group(1);
    if (tag != null) {
      alignStack.add(tag == 'center'
          ? TextAlign.center
          : (tag == 'right' ? TextAlign.right : TextAlign.left));
    } else if (alignStack.isNotEmpty) {
      alignStack.removeLast();
    }
    cursor = m.end;
  }
  emit(html.substring(cursor));
  return blocks;
}

/// 段落 HTML → 内联片段（文字 / 链接 / 样式位）。Public 供夹具测试直测。
///
/// 0.1.35 起维护样式栈：开关标签 `strong/b`、`em/i`、`u`、`strike/s`、`font color`、
/// `font size`；错配标签按「弹出到最近同类」处理，栈不会失衡。
/// `javascript:` 等伪链接拍平成文字；只认 http(s) 链接。
List<ForumInline> parseForumInlines(String html) {
  final out = <ForumInline>[];
  final stack = <_StyleFrame>[];

  ForumInlineStyle styleNow() {
    var s = ForumInlineStyle.none;
    for (final f in stack) {
      s = s.merge(f.style);
    }
    return s;
  }

  String? hrefNow() {
    for (var i = stack.length - 1; i >= 0; i--) {
      final h = stack[i].href;
      if (h != null && h.isNotEmpty) return h;
    }
    return null;
  }

  void addText(String raw) {
    final t = _inlineText(raw);
    if (t.isEmpty) return;
    final style = styleNow();
    final href = hrefNow();
    if (out.isNotEmpty) {
      final last = out.last;
      final sameKind = last.isLink == (href != null) &&
          (!last.isLink || last.href == href) &&
          last.style == style;
      if (sameKind) {
        // 相邻同格式片段合并成一片段（旧行为：纯文本合并）
        out[out.length - 1] = href == null
            ? ForumInline.text(last.text + t, style: style)
            : ForumInline.link(last.text + t, href, style: style);
        return;
      }
    }
    out.add(href == null
        ? ForumInline.text(t, style: style)
        : ForumInline.link(t, href, style: style));
  }

  /// 关闭标签：弹出到最近同类（含它自己）；栈里没有同类则忽略。
  void popTo(String kind) {
    for (var i = stack.length - 1; i >= 0; i--) {
      if (stack[i].kind == kind) {
        stack.removeRange(i, stack.length);
        return;
      }
    }
  }

  var cursor = 0;
  for (final m in _inlineTagRe.allMatches(html)) {
    addText(html.substring(cursor, m.start));
    cursor = m.end;

    final hrefRaw = m.namedGroup('href');
    if (hrefRaw != null) {
      // 站点包图用自闭合 `<a href=… class="orange" />`：不承载文本，忽略
      if (m.namedGroup('selfclose') != '/') {
        final href = decodeEntities(hrefRaw).trim();
        if (href.startsWith('http')) {
          stack.add(_StyleFrame('a', ForumInlineStyle.none, href: href));
        }
      }
      continue;
    }

    final open = m.namedGroup('open');
    if (open != null) {
      switch (open.toLowerCase()) {
        case 'strong' || 'b':
          stack.add(const _StyleFrame('strong', ForumInlineStyle(bold: true)));
        case 'em' || 'i':
          stack.add(const _StyleFrame('em', ForumInlineStyle(italic: true)));
        case 'u':
          stack.add(const _StyleFrame('u', ForumInlineStyle(underline: true)));
        case 'strike' || 's':
          stack.add(const _StyleFrame('strike', ForumInlineStyle(strike: true)));
        case 'font':
          stack.add(_StyleFrame('font', _fontStyle(m.namedGroup('attrs') ?? '')));
      }
      continue;
    }

    final close = m.namedGroup('close');
    if (close != null) {
      final k = close.toLowerCase();
      popTo(k == 'b'
          ? 'strong'
          : k == 'i'
              ? 'em'
              : k == 's'
                  ? 'strike'
                  : k);
      continue;
    }

    // `</a>`
    popTo('a');
  }
  addText(html.substring(cursor));
  return out;
}

/// `<font>` 属性 → 样式位：`color`（`#rrggbb` / `rgb(r,g,b)`）与 `size`（三档）。
/// 白字（`#ffffff`）额外打 [ForumInlineStyle.spoiler] 位——站点用它藏剧透。
ForumInlineStyle _fontStyle(String attrs) {
  var colorHex = '';
  final attrColor = RegExp(
    r'''(?<![\w-])color\s*=\s*["']?([^"'\s>]+)''',
    caseSensitive: false,
  ).firstMatch(attrs)?.group(1);
  // 只认独立的 `color:`（`background-color:` 不算；站点有这种形状）
  final styleColor = RegExp(
    r'''(?<![\w-])color\s*:\s*([^;"']+)''',
    caseSensitive: false,
  ).firstMatch(attrs)?.group(1);
  final rawColor = attrColor ?? styleColor;
  if (rawColor != null) colorHex = _normalizeHexColor(rawColor);

  var sizeStep = 0;
  final size = RegExp(
    r'''(?<![\w-])size\s*=\s*["']?(\d+)''',
    caseSensitive: false,
  ).firstMatch(attrs)?.group(1);
  if (size != null) sizeStep = _sizeStepOf(int.tryParse(size) ?? 3);

  return ForumInlineStyle(
    colorHex: colorHex,
    sizeStep: sizeStep,
    spoiler: colorHex == '#ffffff',
  );
}

/// 站点字号 → 三档：1–2 → -1、3 → 0、4–7 → +1（决策表 §一·字号）。
int _sizeStepOf(int siteSize) {
  if (siteSize <= 0) return 0;
  if (siteSize <= 2) return -1;
  if (siteSize <= 3) return 0;
  return 1;
}

/// 颜色原文 → `#rrggbb`（认 `#rgb` / `#rrggbb` / `rgb(r,g,b)`；认不出返回空串）。
String _normalizeHexColor(String raw) {
  final v = raw.trim().toLowerCase();
  if (v.startsWith('#')) {
    var hex = v.substring(1);
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
    if (hex.length != 6 || !RegExp(r'^[0-9a-f]{6}$').hasMatch(hex)) return '';
    return '#$hex';
  }
  final rgb = RegExp(
    r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)',
    caseSensitive: false,
  ).firstMatch(v);
  if (rgb == null) return '';
  final r = int.tryParse(rgb.group(1)!) ?? 0;
  final g = int.tryParse(rgb.group(2)!) ?? 0;
  final b = int.tryParse(rgb.group(3)!) ?? 0;
  if (r > 255 || g > 255 || b > 255) return '';
  String h(int n) => n.toRadixString(16).padLeft(2, '0');
  return '#${h(r)}${h(g)}${h(b)}';
}

/// 引用块 HTML → [ForumQuote]。
/// 站点形状（thread-5-533721 实抓，一行一段标签链）：
/// `<div class="quote"><blockquote><font size="2"><a href="…findpost…">`
/// `<font color="#999999">作者 发表于 时间</font></a></font><br />被引正文</blockquote></div>`
/// 引用头取第一个 `<br>` 之前的文本；pid 从引用头（或整块）的 findpost 链接提取。
ForumQuote? _parseQuote(String qHtml) {
  final bm = RegExp(r'<blockquote[^>]*>([\s\S]*)</blockquote>', caseSensitive: false)
      .firstMatch(qHtml);
  // 贪婪取到最后一个 </blockquote>：嵌套引用整块进来，内层拍平进文本
  final inner = bm?.group(1) ?? qHtml;
  final br = _paraBreakRe.firstMatch(inner);
  final headerHtml = br == null ? inner : inner.substring(0, br.start);
  final bodyHtml = br == null ? '' : inner.substring(br.end);

  final header = _inlineText(headerHtml);
  var author = header;
  var time = '';
  const sep = ' 发表于 ';
  final at = header.indexOf(sep);
  if (at > 0) {
    author = header.substring(0, at);
    time = header.substring(at + sep.length).trim();
  }

  var pid = '';
  final href = _linkRe.firstMatch(inner)?.group(1);
  if (href != null) {
    // 实抓里 href 是实体编码的（&amp;pid=…），先解码再取 pid
    final decoded = decodeEntities(href);
    if (decoded.contains('findpost')) {
      pid = RegExp(r'[?&]pid=(\d+)').firstMatch(decoded)?.group(1) ?? '';
    }
  }

  final text = blockText(bodyHtml);
  if (header.isEmpty && text.isEmpty && pid.isEmpty) return null;
  return ForumQuote(author: author, time: time, text: text, pid: pid);
}

/// 段内文本：剥标签 + 实体解码 + 折空白（与 blockText 的行内口径一致，不折换行——
/// 切片发生在按 `<br>` 分段之后，段内不该再有换行锚点）。
String _inlineText(String raw) {
  return decodeEntities(raw.replaceAll(RegExp(r'<[^>]*>'), ' '))
      .replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
      .trim();
}

/// 块内文本 → 保留换行的纯文本（摘要用；站点已在服务端截断）。
String blockText(String input) {
  final text = decodeEntities(input
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), ''));
  return text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Discuz showmessage 消息页识别（站方消息兜底，2026-11-15 定调）：
/// 关站/维护/公告时站点对登录用户返回 HTTP 200 + 消息页（游客 302 跳登录，
/// 由 LOGIN_REQUIRED 接住）。文案是管理员自定义的，没法预知——**不赌关键词**，
/// 命中消息页形状就摘站点原文返回，认不出形状返回 null（调用方按原空态处理）。
/// 锚点（touch 核心模板
/// `<div class="jump_c"><p>原文</p>`，正文是第一个 `<p>`、后面几段是
/// 「继续/返回」链接文案；PC 核心 msgbox 内 `alert_info`/`alert_error`）。
/// 站点手机模板是第三方定制（oyeeh），真发生关站时按网络日志实抓核对。
String? forumSiteMessage(String html) {
  final shaped = html.contains('jump_c') ||
      html.contains('msgbox') ||
      html.contains('alert_info') ||
      html.contains('alert_error');
  if (!shaped) return null;
  final jump = RegExp(r'<div class="jump_c[^"]*"[^>]*>([\s\S]*?)</div>').firstMatch(html);
  if (jump != null) {
    final para = RegExp(r'<p[^>]*>([\s\S]*?)</p>').firstMatch(jump.group(1)!);
    if (para != null) {
      final text = stripTags(para.group(1)!);
      if (text.isNotEmpty) return text;
    }
  }
  final alert = RegExp(r'class="alert_(?:info|error)"[^>]*>([\s\S]*?)</div>').firstMatch(html);
  if (alert != null) {
    final text = stripTags(alert.group(1)!);
    if (text.isNotEmpty) return text;
  }
  return null;
}

String absolute(String? url) {
  if (url == null || url.isEmpty) return '';
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return url;
  return url.startsWith('/') ? '$_site$url' : '$_site/$url';
}

String? _first(String html, RegExp re, [int index = 1]) =>
    re.firstMatch(html)?.group(index);

Iterable<RegExpMatch> _all(String html, RegExp re) => re.allMatches(html);

// ---------------------------------------------------------------------------
// 页面级字段
// ---------------------------------------------------------------------------

/// 页面脚本里的 `discuz_uid`：`'0'` = 游客（登录判定口径之一）。
/// 每个论坛页 `<script>` 头部都有这个变量，取不到返回空串。
String discuzUid(String html) =>
    _first(html, RegExp(r'''discuz_uid\s*=\s*'(\d+)''')) ?? '';

/// 页面里的 `formhash`（写操作令牌：收藏 / 签到用）。游客页也有。
/// 真实形态三种都收（2026-11-14 实抓）：
/// 1. 隐藏表单 `<input type="hidden" name="formhash" value="xxxx">`；
/// 2. 页面脚本 `data:{'favoritesubmit':'true', 'formhash':'xxxx'}`；
/// 3. URL 参数 `...&formhash=xxxx&...`。
String formhash(String html) =>
    _first(html, RegExp(r'name="formhash"\s+value="([0-9a-f]+)"')) ??
    _first(html, RegExp(r"'formhash':'([0-9a-f]+)'")) ??
    _first(html, RegExp(r'formhash=([0-9a-f]+)')) ?? '';

/// 页面里「自己的昵称」。登录态的头版锚点（手机模板下 Discuz 会在顶部用户区
/// 印指向自己空间页的链接）没实抓过，这里按 uid 回链尽力取：文本等于常见
/// 占位词（「个人资料」「访问我的空间」等）不算昵称。取不到返回 null——不编，
/// 界面退「已登录」。
String? forumUserName(String html, {required String uid}) {
  if (uid.isEmpty || uid == '0') return null;
  // 注意别在 raw 字符串里写 $uid（不插值，会变成字面量）——
  // 这里先抓「所有空间页链接」，再按捕获的 uid 过滤。
  final matches = _all(
    html,
    RegExp(r'''home\.php\?mod=space(?:&amp;|&)uid=(\d+)[^"]*"[^>]*>([\s\S]{1,40}?)</a>'''),
  );
  const placeholders = {'个人资料', '访问我的空间', '我的空间', '空间', '个人主页'};
  for (final m in matches) {
    if (m.group(1) != uid) continue;
    final name = stripTags(m.group(2) ?? '');
    if (name.isNotEmpty && !placeholders.contains(name) && name != uid) return name;
  }
  return null;
}

/// 板块页：顶栏 `<h2>` 是板块名（forumdisplay 页 header 区第一处 h2）。
String _boardName(String html) =>
    stripTags(_first(html, RegExp(r'<div class="header cl">[\s\S]*?<h2>([\s\S]*?)</h2>')) ?? '');

/// 分页条里的 `共 N 页`（帖子页与板块页共用；帖子页经 _threadTotalPages 包装）。
int _totalPages(String html) {
  final n = int.tryParse(_first(html, RegExp(r'共\s*(\d+)\s*页')) ?? '');
  return (n != null && n > 0) ? n : 0;
}

// ---------------------------------------------------------------------------
// 板块页（forumdisplay）
// ---------------------------------------------------------------------------

/// 列表行起点：置顶 `li.list_top`（捕获组 `_top`）与普通 `li.list`。
/// 内部有嵌套 `<li>`（threadlist_foot），只能按起点切片（见文件头注释）。
final _listStartRe = RegExp(r'<li class="list(_top)?">');

/// 列表块结束的兜底锚点：分页条（没有分页时切到文档尾，多余部分不影响提取）。
final _pgRe = RegExp(r'<div class="pg"');

/// 解析板块一页。置顶在前、普通在后（与站点顺序一致）。
ForumBoardData parseBoardPage(String html, {required String fid, int page = 1}) {
  final starts = _all(html, _listStartRe).toList();
  final threads = <ForumThreadSummary>[];
  final pgAfter = _pgRe.firstMatch(html)?.start ?? html.length;

  for (var i = 0; i < starts.length; i++) {
    final start = starts[i].start;
    final end = i + 1 < starts.length ? starts[i + 1].start : pgAfter;
    if (end <= start) continue;
    final t = starts[i].group(1) != null
        ? _parsePinned(html.substring(start, end))
        : _parseThread(html.substring(start, end));
    if (t != null) threads.add(t);
  }

  return ForumBoardData(
    fid: fid,
    boardName: _boardName(html),
    subBoards: _parseSubBoards(html),
    typeTags: _parseTypeTags(html),
    threads: threads,
    page: page,
    totalPages: _totalPages(html),
  );
}

/// 子版块：`<div class="forumlist">` 里 `<span class="subforumshow">子版块</span>`
/// 紧跟一排 `<a class="murl" href="…fid=N"><p class="mtit">名字</p></a>`。
///
/// ⚠ 首页也有 `.sub-forum` 块（`parseForumHome` 解的那份），两者 class 同族但语义不同：
/// 首页那个是「板块」，这里是「某板块下的子版」。所以只在板块页解析，不共用。
/// 子版行的 `p.mtit` 里没有首页那种 `<span class="mnum">今日 N</span>`；
/// 但仍按「今日」截断一次，站点模板改动时不会把数字吃进名字。
List<ForumSubBoard> _parseSubBoards(String html) {
  final start = html.indexOf('<div class="forumlist');
  if (start < 0) return const <ForumSubBoard>[];
  final end = html.indexOf('<div class="threadlist', start);
  final block = html.substring(start, end < 0 ? html.length : end);

  final out = <ForumSubBoard>[];
  final re = RegExp(
    r'<a href="[^"]*?fid=(\d+)[^"]*" class="murl">\s*<p class="mtit">([\s\S]*?)</p>',
  );
  for (final m in re.allMatches(block)) {
    final raw = stripTags(m.group(2)!);
    final name = raw.split('今日').first.trim();
    if (name.isEmpty) continue;
    out.add(ForumSubBoard(fid: m.group(1)!, name: name));
  }
  return out;
}

/// 主题分类：`#dhnavs_li` 横滑条，每项 `…&filter=typeid&typeid=M">名字</a>`。
///
/// 排序条 `#dhnav_li` 在它**前面**，所以起点取 `dhnavs_li`、终点取子版块/列表块，
/// 不会把排序那几档（全部/最新/热门/新帖/精华）误当分类。
List<ForumTypeTag> _parseTypeTags(String html) {
  final start = html.indexOf('id="dhnavs_li"');
  if (start < 0) return const <ForumTypeTag>[];

  // 结束锚点取 swiper 自己的收口 `</ul>`。
  // ⚠ 曾经用「下一个 <div class="forumlist」当终点：**没有子版块的板块**（使用指南 fid=370）
  //   里根本没有这个块，`indexOf` 返回 -1 就一路吃到文档尾——列表行脚部的 `#论坛指南`
  //   是同一个 typeid 的链接，于是 3 个分类被收成十几个（2026-11-17 用户实测发现）。
  final end = html.indexOf('</ul>', start);
  final block = html.substring(start, end < 0 ? html.length : end);

  final out = <ForumTypeTag>[];
  // 同一 typeid 只留第一次（条子里偶有重复 <li>，站点模板改动时也不至于翻倍）
  final seen = <String>{};
  final re = RegExp(r'filter=typeid(?:&amp;|&)typeid=(\d+)[^"]*">([^<]+)</a>');
  for (final m in re.allMatches(block)) {
    final typeid = m.group(1)!;
    final name = stripTags(m.group(2)!).trim();
    if (name.isEmpty || !seen.add(typeid)) continue;
    out.add(ForumTypeTag(typeid: typeid, name: name));
  }
  return out;
}

String? _tidOf(String block) => _first(block, RegExp(r'tid=(\d+)'));

String? _miconOf(String block) =>
    stripTags(_first(block, RegExp(r'<span class="micon[^"]*">([\s\S]*?)</span>')) ?? '');

/// 标题：优先 `<em>`（有角标的行标题都包在 em 里），退回块内文本。
String? _titleOf(String block) {
  final em = _first(block, RegExp(r'<em[^>]*>([\s\S]*?)</em>'));
  if (em != null && stripTags(em).isNotEmpty) return stripTags(em);
  return null;
}

/// 置顶行：`<a href=…tid=…><span class="micon">置顶</span><em>标题</em></a>`。
/// 公告行没有 tid（链接指向 announcement），tid 留空串。
ForumThreadSummary? _parsePinned(String block) {
  final title = _titleOf(block);
  if (title == null || title.isEmpty) return null;
  return ForumThreadSummary(
    tid: _tidOf(block) ?? '',
    title: title,
    badge: _miconOf(block) ?? '',
    pinned: true,
  );
}

/// 普通主题行。字段全部按锚点取，取不到就空——不编。
ForumThreadSummary? _parseThread(String block) {
  final tid = _tidOf(block);
  final title = _titleOf(block);
  if ((tid == null || tid.isEmpty) && (title == null || title.isEmpty)) {
    return null;
  }

  // threadlist_tit 内的 micon（精华 / 投票），与行首头像区的 micon 无关
  final tit = _first(block, RegExp(r'<div class="threadlist_tit cl">([\s\S]*?)</div>')) ?? '';

  final excerpt = _first(block, RegExp(r'<div class="threadlist_mes cl">([\s\S]*?)</div>'));

  // foot 里：分类 tag（li.mr）、阅读数（dm-eye-fill）、回复数（dm-chat-s-fill）
  final foot = _first(block, RegExp(r'<div class="threadlist_foot cl">([\s\S]*?)</div>')) ?? '';
  final typeTag = stripTags(_first(foot, RegExp(r'<li class="mr"><a[^>]*>([\s\S]*?)</a>')) ?? '')
      .replaceFirst(RegExp(r'^#'), '');
  final views = int.tryParse(
          (_first(foot, RegExp(r'dm-eye-fill[^>]*></i>\s*([\d,]+)')) ?? '')
              .replaceAll(',', '')) ??
      0;
  final replies = int.tryParse(
          (_first(foot, RegExp(r'dm-chat-s-fill[^>]*></i>\s*([\d,]+)')) ?? '')
              .replaceAll(',', '')) ??
      0;

  return ForumThreadSummary(
    tid: tid ?? '',
    title: title ?? '',
    badge: _miconOf(tit) ?? '',
    typeTag: typeTag,
    author: stripTags(_first(block, RegExp(r'''class="mmc">([^<]*)</a>''')) ?? ''),
    authorUid: _first(block, RegExp(r'space&amp;uid=(\d+)')) ?? '',
    time: stripTags(_first(block, RegExp(r'''class="mtime">([^<]*)</span>''')) ?? ''),
    excerpt: excerpt == null ? '' : blockText(excerpt),
    views: views,
    replies: replies,
  );
}

// ---------------------------------------------------------------------------
// 用户资料页（home.php?mod=space&mycenter=1&mobile=2 · 第十七期）
// ---------------------------------------------------------------------------

/// 昵称：`<h2 class="name">…</h2>`（头卡里那一个，不在 myinfo_list 里）。
final _profileNameRe = RegExp(r'<h2 class="name">([\s\S]*?)</h2>');

/// 三格的一格：`<li><span>值</span>标签</li>`——**值在标签前**。
final _userBoxCellRe =
    RegExp(r'<li[^>]*>\s*<span[^>]*>([\s\S]*?)</span>([\s\S]*?)</li>');

/// 一行资料：`<li>标签<span>值</span></li>`——**值在标签后**。
final _profileCellRe = RegExp(r'<span[^>]*>([\s\S]*?)</span>');

/// 资料页解析。`uid` 是请求时带的 uid，只在页面里没印 UID 行时兜底。
///
/// ⚠ 页面上有**两套顺序相反**的结构，必须分开写，别想着合并：
/// - 三格（`div.user_box`）：`<li><span>值</span>标签</li>`，**值在标签前**；
/// - 资料行（`div.myinfo_list`）：`<li>标签<span>值</span></li>`，**值在标签后**。
/// 写反了就是「标签当值」，而且页面上看起来还挺像那么回事。
///
/// 切块口径同列表行：按「下一个 `<li` 起点」切，不用懒匹配 `</li>`
/// （`li.sig` 里有 `<br>` 和链接，两种匹配都会踩边界）。
///
/// 名字与资料行**都**取不到 = 这不是资料页（消息页 / 模板改版），抛 `PARSE`
/// 交给取数层翻成人话；只缺一两行不算，缺的行就是不出现。
ForumProfile parseUserProfile(String html, {String uid = ''}) {
  final name = stripTags(_first(html, _profileNameRe) ?? '');

  // 三格：值在标签前
  //
  // ⚠ 只按 `class="user_box` 前缀切块，**别写成整串 `<div class="user_box cl">`**：
  // 站点在这块上挂了 `onclick`（点三格跳积分日志），开标签是
  // `<div class="user_box cl" onclick="…">`，整串匹配一次都不命中，三格就全成 null。
  int? totalPoints;
  int? points;
  int? partner;
  final boxAt = html.indexOf('<div class="user_box');
  if (boxAt >= 0) {
    final closeAt = html.indexOf('</ul>', boxAt);
    final chunk = html.substring(boxAt, closeAt < 0 ? html.length : closeAt);
    for (final m in _all(chunk, _userBoxCellRe)) {
      final label = stripTags(m.group(2) ?? '');
      final n = _profileInt(stripTags(m.group(1) ?? ''));
      switch (label) {
        case '总积分':
          totalPoints = n;
        case '积分':
          points = n;
        case '对象':
          partner = n;
      }
    }
  }

  // 签名：单独占一个 myinfo_list 块，`<br>` 转换行（本期不做富文本）
  var signature = '';
  final sigAt = html.indexOf('<li class="sig');
  if (sigAt >= 0) {
    final bodyAt = html.indexOf('>', sigAt) + 1;
    final end = _firstPositive([
      html.indexOf('<li', bodyAt),
      html.indexOf('</ul>', bodyAt),
      html.length,
    ]);
    if (bodyAt > 0 && end > bodyAt) {
      signature = blockText(html.substring(bodyAt, end));
    }
  }

  // 资料行：遍历**所有** myinfo_list 块（他人视角有两个：签名块 + 资料块）
  final fields = <ForumProfileField>[];
  var group = '';
  var adminGroup = '';
  var registerTime = '';
  var lastVisit = '';
  int? onlineHours;
  var parsedUid = '';
  var settingsRow = false;

  var from = 0;
  while (true) {
    final start = html.indexOf('<div class="myinfo_list cl"', from);
    if (start < 0) break;
    final next = html.indexOf('<div class="myinfo_list', start + 1);
    final end = next < 0 ? html.length : next;
    for (final row in _profileRows(html.substring(start, end))) {
      // 签名那一条已经单独取过，别当资料行
      if (row.contains('class="sig"')) continue;
      final cell = _profileCellRe.firstMatch(row);
      // 没有 `<span>` = 标题行（`<b>个人资料</b>` / `<b>个人签名</b>` 那一类）
      if (cell == null) continue;
      final label = stripTags(row.substring(0, cell.start));
      if (label.isEmpty) continue;
      // 自己视角的表头行是 `<b>个人资料</b><span><a>设置</a></span>`：
      // 它的「值」是动作而不是资料，但要拿来判 isSelf
      if (label == '个人资料' || label == '个人签名') {
        if (stripTags(cell.group(1) ?? '').contains('设置')) settingsRow = true;
        continue;
      }
      final value = _profileValue(stripTags(cell.group(1) ?? ''));
      if (value == null) continue;
      switch (label) {
        case '用户组':
          group = value;
        case '管理组':
          adminGroup = value;
        // 最后访问归头卡，资料表里不再重复同一件事实
        case '最后访问':
          lastVisit = value;
        case 'UID':
          parsedUid = value;
          fields.add(ForumProfileField(label: label, value: value));
        case '在线时间':
          onlineHours = _profileInt(value);
          fields.add(ForumProfileField(label: label, value: value));
        case '注册时间':
          registerTime = value;
          fields.add(ForumProfileField(label: label, value: value));
        default:
          fields.add(ForumProfileField(label: label, value: value));
      }
    }
    if (end >= html.length) break;
    from = end;
  }

  if (name.isEmpty && fields.isEmpty) {
    throw YmHttpError('没能认出资料页', code: 'PARSE');
  }

  return ForumProfile(
    uid: parsedUid.isNotEmpty ? parsedUid : uid,
    name: name,
    group: group,
    adminGroup: adminGroup,
    signature: signature,
    formhash: formhash(html),
    registerTime: registerTime,
    lastVisit: lastVisit,
    totalPoints: totalPoints,
    points: points,
    partner: partner,
    onlineHours: onlineHours,
    fields: fields,
    isSelf: settingsRow || html.contains('btn_exit'),
  );
}

/// 一个 myinfo_list 块里的所有 `<li>` 段（按下一个 `<li` 起点切）。
List<String> _profileRows(String block) {
  final starts = _all(block, RegExp(r'<li[ >]')).toList();
  final out = <String>[];
  for (var i = 0; i < starts.length; i++) {
    final from = starts[i].start;
    final to = i + 1 < starts.length ? starts[i + 1].start : block.length;
    if (to > from) out.add(block.substring(from, to));
  }
  return out;
}

/// 资料值归一：空串 / `-` / 默认的裸协议头一律当「站点没给」。
/// 归一后是 null 的行整行不出现（不印占位符）。
String? _profileValue(String raw) {
  final v = raw.trim();
  if (v.isEmpty || v == '-' || v == '--' || v == '—') return null;
  // Discuz 的「没填」默认值就是一个空协议头（个人主页这类字段）
  if (v == 'http://' || v == 'https://') return null;
  return v;
}

/// 只留数字：`12000 点` → 12000、`9358 小时` → 9358。没有数字就是 null。
int? _profileInt(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}

/// 一组下标里最小且非负的那个（`indexOf` 找不到时是 -1）。
int _firstPositive(List<int> values) {
  var best = -1;
  for (final v in values) {
    if (v < 0) continue;
    if (best < 0 || v < best) best = v;
  }
  return best;
}

/// 空间页（`home.php?mod=space…&do=thread&view=me`）「还有下一页吗」。
///
/// ⚠ 分页条在**线上**是 `<div class="pg">`（2026-11-27 真机抓到的原文：
/// `<div class="pg"><a class="nxt" href="…&page=2&mobile=2">下一页</a></div>`），
/// 而我们手上那份样本写的是 `<div class="page">` —— 两种都认，别只认一种。
///
/// 里面没有页码、**站点不给总页数**（`_totalPages()` 认的是「共 N 页」，在这里恒为 0，
/// 不能当页数用），所以只有这一条判据：块里存在**带 `href` 的「下一页」**就还有下一页。
///
/// 首尾不对称：首页只有「下一页」，末页只有「上一页」，所以不能按按钮在左/右分支，
/// 只能看那个「下一页」自己带不带 href。
///
/// 判据按「逐个 `<a>` 看开标签有没有 href、文字里有没有『下一页』」来判，
/// 不写死 `>下一页<` 这种紧邻形状：站点给按钮加图标（`<i>`）时那种写法会静默失效。
bool userThreadsHasNext(String html) {
  final head = RegExp(r'<div class="(?:page|pg)[\s">]').firstMatch(html);
  if (head == null) return false;
  final at = head.start;
  final close = html.indexOf('</div>', at);
  final block = html.substring(at, close < 0 ? html.length : close);
  for (final m in RegExp(r'<a\b([^>]*)>([\s\S]*?)</a>').allMatches(block)) {
    final attrs = m.group(1) ?? '';
    if (!attrs.contains('href=')) continue;
    if (stripTags(m.group(2) ?? '').contains('下一页')) return true;
  }
  return false;
}
