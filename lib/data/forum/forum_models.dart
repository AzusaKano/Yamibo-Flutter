/// 论坛数据模型（只服务论坛侧，与阅读侧 `models.dart` 无关）。
///
/// 字段拿不到就留空 / 0，**不编造**（界面层按空值给人话提示，见落地方案 §6）。
/// 先只有板块页需要的模型；首页 / 帖子 / 搜索模型随各期补。
library;

import 'dart:ui' show TextAlign;

/// 板块页里的一条主题（置顶行与普通行共用，用 [pinned] 区分）。
class ForumThreadSummary {
  const ForumThreadSummary({
    required this.tid,
    this.title = '',
    this.badge = '',
    this.typeTag = '',
    this.author = '',
    this.authorUid = '',
    this.time = '',
    this.excerpt = '',
    this.views = 0,
    this.replies = 0,
    this.pinned = false,
  });

  /// 主题 id。置顶公告可能没有（链接指向 announcement），留空串；
  /// 界面层对空 tid 的行不做可点承诺。
  final String tid;

  final String title;

  /// 行内角标原文：置顶 / 精华 / 投票 / 公告…（站点给什么是什么）。
  final String badge;

  /// 板块内分类：公告 / 漫画讨论…（站点原文，不带 #）。
  final String typeTag;

  final String author;
  final String authorUid;

  /// 站点原文（如 `2026-11-13 20:57`），不转格式不猜时区。
  final String time;

  /// 列表摘要（纯文本，站点已截断）。
  final String excerpt;

  final int views;
  final int replies;
  final bool pinned;
}

/// 板块一页（forumdisplay）的解析结果。
/// 板块下的子版块（Discuz 的 sub-forum）。
///
/// 站点结构：板块页 `<div class="forumlist">` → `<span class="subforumshow">子版块</span>`
/// → 一排 `<a class="murl" href="…fid=N"><p class="mtit">名字</p></a>`。
/// 点进去是**另一个板块页**（同一个 [ForumBoardData] 形状），不是帖子列表。
class ForumSubBoard {
  const ForumSubBoard({required this.fid, required this.name});

  final String fid;
  final String name;
}

/// 板块的主题分类（Discuz 的 typeid）。
///
/// 站点结构：`#dhnavs_li` 横滑条里每项 `forum.php?mod=forumdisplay&fid=N&filter=typeid&typeid=M`。
/// 名字是站点原文（公告 / 活动 / 动画讨论 …），不带 `#`。
class ForumTypeTag {
  const ForumTypeTag({required this.typeid, required this.name});

  final String typeid;
  final String name;
}

class ForumBoardData {
  const ForumBoardData({
    required this.fid,
    this.boardName = '',
    this.subBoards = const <ForumSubBoard>[],
    this.typeTags = const <ForumTypeTag>[],
    this.threads = const <ForumThreadSummary>[],
    this.page = 1,
    this.totalPages = 0,
  });

  final String fid;
  final String boardName;

  /// 这个板块下的子版块（站点 `.forumlist` 里那一行「子版块」）。
  ///
  /// 大多数板块没有（動漫區只有「百合会最萌世界杯专版」一个），所以 UI 要按「有才画」。
  final List<ForumSubBoard> subBoards;

  /// 主题分类（站点 `#dhnavs_li` 横滑条：公告 / 活动 / 动画讨论 / 漫画讨论 …）。
  ///
  /// ⚠ 站点把「排序」和「分类」塞进同一个 `filter` 参数（`filter=lastpost` vs
  /// `filter=typeid&typeid=N`），两者**不能同时给**——选了分类就要把排序复位，反之亦然。
  final List<ForumTypeTag> typeTags;

  /// 置顶在前、普通主题在后（与站点顺序一致），用 [ForumThreadSummary.pinned] 区分。
  final List<ForumThreadSummary> threads;

  final int page;

  /// 0 = 站点没给分页信息（当单页处理，不给「下一页」承诺）。
  final int totalPages;

  bool get hasNext => totalPages > 0 && page < totalPages;
}

// ---------------------------------------------------------------------------
// 论坛首页（A 屏）
// ---------------------------------------------------------------------------

/// 首页的一块分区卡（站点首页的 庙堂 / 江湖 …分组）。
class ForumCat {
  const ForumCat({required this.name, required this.forums});
  final String name;
  final List<ForumBoardRef> forums;
}

/// 分区卡里的一行板块。
/// [today] 为 null = 站点没印今日数（游客态很多板块不印），界面不编数。
class ForumBoardRef {
  const ForumBoardRef({
    required this.fid,
    required this.name,
    this.desc = '',
    this.today,
  });
  final String fid;
  final String name;
  final String desc;
  final int? today;
}

/// 论坛首页解析结果。
class ForumHome {
  const ForumHome({
    this.announcements = const <String>[],
    this.cats = const <ForumCat>[],
  });

  /// 公告标题（首页滚动公告条，站点原文）。
  final List<String> announcements;
  final List<ForumCat> cats;
}

// ---------------------------------------------------------------------------
// 帖子页（C 屏）
// ---------------------------------------------------------------------------

/// 楼层里的一条点评。
class ForumComment {
  const ForumComment({
    required this.author,
    required this.time,
    required this.text,
  });
  final String author;
  final String time;
  final String text;
}

/// 楼层的评分摘要。明细条目数与人数可能不一致（站点只给一页明细），
/// 全部按站点原文展示，不推算。
class ForumRate {
  const ForumRate({
    required this.people,
    required this.score,
    required this.items,
  });

  final int people;
  final int score;

  /// (用户, 加分, 理由)。理由可能为空。
  final List<ForumRateItem> items;
}

class ForumRateItem {
  const ForumRateItem({
    required this.name,
    required this.delta,
    required this.reason,
  });
  final String name;
  final int delta;
  final String reason;
}

/// 首楼投票（未投态：游客看不到票数，站点就不给，不编百分比）。
class ForumPoll {
  const ForumPoll({required this.options, this.info = '', this.end = '', this.guestNote = ''});

  /// 说明行，如「多选投票: ( 最多可选 5 项 ), 共有 832 人参与投票」。
  final String info;

  /// 截止行，如「距结束还有: 28939 天 16 小时 57 分钟」。
  final String end;

  /// 选项名（站点原文，含序号前缀的剥掉序号后剩下的名字）。
  final List<String> options;

  /// 游客态提示（站点原文，如「您需要登录之后方能进行投票」）。
  final String guestNote;
}

// ---------------------------------------------------------------------------
// 楼层正文富文本结构（0.1.22 · 阶段 5：链接可点 + 引用块）
// ---------------------------------------------------------------------------

/// 正文内联样式位（0.1.35 · 第十期）：一个不可变 value 类，不塞十个 bool。
///
/// - [colorHex] 作者原文色（`#rrggbb`，空 = 未指定）。**模型只存原文**，
///   亮度限幅 / 遮罩换算留到渲染层（`forumReadableColor`），见决策表 §六·1。
/// - [sizeStep] 字号三档：-1 小 / 0 正文 / +1 大（站点 `size` 1–2 / 3 / 4–7 的映射）。
/// - [spoiler] 白字剧透位（`<font color="#ffffff">`）：渲染成可点开的遮罩。
class ForumInlineStyle {
  const ForumInlineStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.colorHex = '',
    this.sizeStep = 0,
    this.spoiler = false,
  });

  /// 无样式片段。
  static const ForumInlineStyle none = ForumInlineStyle();

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /// 作者原文色（`#rrggbb`；空串 = 未指定）。
  final String colorHex;

  /// 字号档位：-1 / 0 / +1。
  final int sizeStep;

  /// 与背景过近的白字剧透（站点用它藏字）。
  final bool spoiler;

  bool get isPlain =>
      !bold &&
      !italic &&
      !underline &&
      !strike &&
      colorHex.isEmpty &&
      sizeStep == 0 &&
      !spoiler;

  /// 嵌套标签叠加：[other] 是内层，内层已声明的位覆盖外层。
  ForumInlineStyle merge(ForumInlineStyle other) {
    if (other.isPlain) return this;
    if (isPlain) return other;
    return ForumInlineStyle(
      bold: bold || other.bold,
      italic: italic || other.italic,
      underline: underline || other.underline,
      strike: strike || other.strike,
      colorHex: other.colorHex.isNotEmpty ? other.colorHex : colorHex,
      sizeStep: other.sizeStep != 0 ? other.sizeStep : sizeStep,
      spoiler: spoiler || other.spoiler,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ForumInlineStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strike == strike &&
      other.colorHex == colorHex &&
      other.sizeStep == sizeStep &&
      other.spoiler == spoiler;

  @override
  int get hashCode =>
      Object.hash(bold, italic, underline, strike, colorHex, sizeStep, spoiler);

  @override
  String toString() => 'ForumInlineStyle(bold: $bold, italic: $italic, '
      'underline: $underline, strike: $strike, colorHex: $colorHex, '
      'sizeStep: $sizeStep, spoiler: $spoiler)';
}

/// 正文内联片段：纯文字或链接。链接文本是剥干净标签的纯文字
///（站点有 `<font color>` 包链接文本的形状，剥到文本），[href] 已实体解码。
class ForumInline {
  const ForumInline.text(this.text, {this.style = ForumInlineStyle.none})
      : href = null;
  const ForumInline.link(this.text, this.href,
      {this.style = ForumInlineStyle.none});

  final String text;

  /// null = 纯文字片段。
  final String? href;

  /// 内联样式位（0.1.35 起；旧调用点不传即 none，语义不变）。
  final ForumInlineStyle style;

  bool get isLink => href != null && href!.isNotEmpty;
}

/// 引用块数据。引用头按「作者 发表于 时间」拆开，拆不开整行给 [author]——不编；
/// [pid] 从引用头的 findpost 链接提取（跳原楼层用），取不到留空 = 不可点。
class ForumQuote {
  const ForumQuote({
    this.author = '',
    this.time = '',
    this.text = '',
    this.pid = '',
  });

  final String author;
  final String time;

  /// 引用正文（纯文本；嵌套引用在这里拍平，不递归展开、不丢字）。
  final String text;
  final String pid;
}

/// 楼层正文块：引用可以出现在正文中间（不是只在开头），位置在这里保留。
sealed class ForumBlock {
  const ForumBlock();
}

/// 普通文字段落（段内可混链接片段 + 样式位）。
class ForumParaBlock extends ForumBlock {
  const ForumParaBlock(this.inlines, {this.align = TextAlign.start});

  final List<ForumInline> inlines;

  /// 段落对齐：只有站点 `<div align="center">` 的段落给 center，其余默认 start。
  final TextAlign align;

  /// 段落纯文本（链接只取文字，**样式位不进文本**——旧消费口径逐字节不变）。
  String get text => inlines.map((e) => e.text).join();
}

/// 引用块。
class ForumQuoteBlock extends ForumBlock {
  const ForumQuoteBlock(this.quote);

  final ForumQuote quote;
}

/// 分割线（站点 `<hr />`，基线 31 处：568572 27 + 556336 4）。
class ForumDividerBlock extends ForumBlock {
  const ForumDividerBlock();
}

/// 正文图（回到句子原位）。[url] 显示图；[originalUrl] 只有包图
/// （`ul.img_one > li > a.orange`）才给原图地址；[caption] 取 `alt`。
/// `ForumPost.images` 仍保留（图片查看器同帖连看依赖它）。
class ForumImageBlock extends ForumBlock {
  const ForumImageBlock({
    required this.url,
    this.originalUrl = '',
    this.caption = '',
  });

  final String url;
  final String originalUrl;
  final String caption;
}

/// 折叠块（站点 `showcollapse_box`）：标题 + 可递归的子块。
/// 渲染默认展开（站点上它是作者分段标记），点标题可收起。
class ForumCollapseBlock extends ForumBlock {
  const ForumCollapseBlock({required this.title, this.blocks = const <ForumBlock>[]});

  final String title;
  final List<ForumBlock> blocks;
}

/// 附件列表（站点 `ul.post_attlist`，基线 1 处：578436）。
class ForumAttachmentBlock extends ForumBlock {
  const ForumAttachmentBlock(this.items);

  final List<ForumAttachment> items;
}

/// 附件项：[name] 文件名、[size] 站点原文大小、[href] 站内下载地址。
class ForumAttachment {
  const ForumAttachment({required this.name, this.size = '', this.href = ''});

  final String name;
  final String size;
  final String href;
}

/// 帖子一页里的一个楼层。
class ForumPost {
  const ForumPost({
    required this.pid,
    required this.floor,
    this.author = '',
    this.authorUid = '',
    this.time = '',
    this.blocks = const <ForumBlock>[],
    this.images = const <String>[],
    this.comments = const <ForumComment>[],
    this.rate,
    this.poll,
  });

  final String pid;
  final int floor;
  final String author;
  final String authorUid;

  /// 站点原文时间（如 `2025-5-21 22:33`）。
  final String time;

  /// 楼层正文块（段落 + 引用，位置保留）。
  final List<ForumBlock> blocks;

  /// 纯文本段落视图（0.1.21 及以前的消费口径；引用块文本不在这里）。
  List<String> get paragraphs => <String>[
        for (final b in blocks)
          if (b is ForumParaBlock && b.text.isNotEmpty) b.text,
      ];

  /// 正文里的图（绝对地址；表情图不收；引用块里的图也计入——与拍平口径一致）。
  final List<String> images;
  final List<ForumComment> comments;
  final ForumRate? rate;
  final ForumPoll? poll;
}

/// 首楼目录的一条（作品帖作者手写的 findpost 锚点）。
///
/// 身份是 [pid]，不是标题：分卷时会出现两个「第一章」。
/// 番外 / 人设 / 设定整理这些作者列进来的条目照原样收，不筛不分类。
class ForumTocEntry {
  const ForumTocEntry({required this.pid, required this.title});

  final String pid;
  final String title;
}

/// 帖子一页的解析结果。
class ForumThreadPage {
  const ForumThreadPage({
    required this.tid,
    this.title = '',
    this.tag = '',
    this.boardName = '',
    this.views = 0,
    this.replies = 0,
    this.posts = const <ForumPost>[],
    this.page = 1,
    this.totalPages = 0,
    this.toc = const <ForumTocEntry>[],
    this.fid = '',
    this.fromCache = false,
  });

  final String tid;
  final String title;

  /// 分类标签原文（如「杂谈」，站点写在 [杂谈] 里）。
  final String tag;
  final String boardName;

  /// 浏览 / 回复数（站点在首楼作者行印的统计，游客可见）。
  final int views;
  final int replies;

  final List<ForumPost> posts;
  final int page;
  final int totalPages;

  /// 首楼目录（本次页面会话内存活，不持久化）。没有目录就是空列表。
  final List<ForumTocEntry> toc;

  /// 板块号（回帖表单 URL 里的 `fid`，0.1.38 从帖页 HTML 的回帖链接里抓）。
  /// 只用于拼回帖表单地址；取不到是空串（表单页不带 fid 也能开，不编板块号）。
  final String fid;

  /// 这一页是**从本机离线副本读出来的**（第三期）。界面据此标「离线」，
  /// 并且知道「刷新」能拿到更新的一版。解析器不填，只有 [forum_api] 的
  /// 读盘分支填 true。
  final bool fromCache;

  ForumThreadPage copyWith({bool? fromCache}) => ForumThreadPage(
    tid: tid,
    title: title,
    tag: tag,
    boardName: boardName,
    views: views,
    replies: replies,
    posts: posts,
    page: page,
    totalPages: totalPages,
    toc: toc,
    fid: fid,
    fromCache: fromCache ?? this.fromCache,
  );

  bool get hasNext => totalPages > 0 && page < totalPages;
}
