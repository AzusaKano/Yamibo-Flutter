import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../data/forum/forum_models.dart';
import '../../pressable.dart';
import '../../theme.dart';
import '../../theme/forum_color.dart';
import '../../tokens.dart';
import 'forum_image.dart' show YmForumImage;

/// 次要件（引用 / 折叠标题 / 附件 / 图注）按与正文的比例跟随基准换算：
/// 基准变了这些小字一起走，不留在原来的绝对像素上。基准为 15 时结果与原来逐字相等。
double _scaled(double base, double unit) => base * unit / YmFont.body15;

/// 楼层正文块流（0.1.35 · 第十期从 F-04 楼层卡里拆出的可复用件）。
///
/// 按 [ForumPost.blocks] 顺序铺：段落（内联样式 + 链接 + 剧透遮罩）、引用、
/// 分割线、原位图、折叠块（可递归）、附件行。
///
/// 链接 / 引用头用 `TextSpan` + `TapGestureRecognizer`（**不用 WidgetSpan**：
/// 长链接文本要能跨行折行，WidgetSpan 折不了）；手势与剧透展开态都归本件管理，
/// 所以是 Stateful。块与块之间统一 8px（引用块自带的内距不算）。
///
/// 第十五期起支持**分页模式**的三根插线（都是可选，不传 = 滚动模式现状）：
/// 剧透展开态外置（[revealed] / [onReveal]）、剧透键序号基址（[seqBase]）、
/// 块高度变化回调（[onBlockLayoutChanged]）。
class YmForumBody extends StatefulWidget {
  const YmForumBody({
    super.key,
    required this.blocks,
    this.pid = '',
    this.level = 0,
    this.fontSize,
    this.lineHeight,
    this.onOpenLink,
    this.onOpenImage,
    this.revealed,
    this.onReveal,
    this.seqBase = 0,
    this.onBlockLayoutChanged,
  });

  final List<ForumBlock> blocks;

  /// 楼层 pid（剧透展开态的键前缀，不跨楼层串）。
  final String pid;

  /// 折叠嵌套层级（缩进 12px，最多两级）。
  final int level;

  /// 正文基准字号 / 行距（0.1.37 · 第十三期）。
  ///
  /// **不传 = 保持帖子页现状**（body15 + 1.72），一个 byte 都不变；
  /// 只有阅读器传 [`readerPrefs`] 的值进来。内联三档与次要件都按这个基准等比换算。
  final double? fontSize;
  final double? lineHeight;

  final void Function(String href)? onOpenLink;
  final void Function(String url)? onOpenImage;

  /// 已展开剧透键集合（**外置**，分页模式用）。分页后每页是独立实例，
  /// 展开态必须提到分页容器活过重建；给 [revealed] 就必须给 [onReveal]，
  /// 不给时展开态落在本件内部（滚动模式现状，逐字节不变）。
  final Set<String>? revealed;

  /// 剧透展开回调（键 = pid + 片段序号，父级落集合并触发重建）。
  final ValueChanged<String>? onReveal;

  /// 片段序号基址：剧透键的序号按渲染顺序计数，分页切片后不传基址
  /// 会跨页撞键（第 2 页的第 0 个片段会开第 1 页的第 0 个剧透）。
  /// 嵌套折叠块内部沿用旧口径（自成一体，不接基址）。
  final int seqBase;

  /// 块高度变化回调：图片解码完（占位 → 实图）、折叠块收起/展开时触发，
  /// 分页引擎靠它发起重排。滚动模式用不上（列表自己长高）。
  final VoidCallback? onBlockLayoutChanged;

  @override
  State<YmForumBody> createState() => _YmForumBodyState();
}

class _YmForumBodyState extends State<YmForumBody> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  /// 本件内部的剧透展开态（外置集合不传时才用）。
  final Set<String> _ownRevealed = <String>{};

  /// 剧透展开态读取口径：外置给了就用外置（分页模式），没有用内部（现状）。
  Set<String> get _revealed => widget.revealed ?? _ownRevealed;

  /// 本次 build 的片段序号（按渲染顺序递增，重建时稳定；分页切片从
  /// [YmForumBody.seqBase] 起算，键不跨页串）。
  int _seq = 0;

  /// 正文基准字号：没传就是帖子页原来的 15。
  double get _base => widget.fontSize ?? YmFont.body15;

  /// 正文行距：没传就是帖子页原来的 1.72（书面例外 E-1）。
  double get _lineHeight => widget.lineHeight ?? 1.72;

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _seq = widget.seqBase;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildBlocks(context),
    );
  }

  List<Widget> _buildBlocks(BuildContext context) {
    final c = YmScope.of(context).colors;
    final children = <Widget>[];

    void gap() {
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
    }

    for (final block in widget.blocks) {
      switch (block) {
        case final ForumParaBlock para:
          gap();
          children.add(_para(para, c));
        case final ForumQuoteBlock quoted:
          gap();
          children.add(
            _QuoteBox(
              quote: quoted.quote,
              base: _base,
              onJump: _quoteJump(quoted.quote),
            ),
          );
        case ForumDividerBlock():
          gap();
          children.add(_Divider());
        case final ForumImageBlock image:
          gap();
          children.add(_image(image, c));
        case final ForumCollapseBlock collapse:
          gap();
          children.add(
            _CollapseView(
              block: collapse,
              level: widget.level,
              pid: widget.pid,
              base: _base,
              lineHeight: _lineHeight,
              onOpenLink: widget.onOpenLink,
              onOpenImage: widget.onOpenImage,
              onLayoutChanged: widget.onBlockLayoutChanged,
            ),
          );
        case final ForumAttachmentBlock att:
          gap();
          children.add(
            _Attachments(
              block: att,
              base: _base,
              onOpenLink: widget.onOpenLink,
            ),
          );
      }
    }
    return children;
  }

  VoidCallback? _quoteJump(ForumQuote quote) {
    if (widget.onOpenLink == null || quote.pid.isEmpty) return null;
    return () => widget.onOpenLink!(
      'https://bbs.yamibo.com/forum.php?mod=redirect'
      '&goto=findpost&pid=${quote.pid}',
    );
  }

  Widget _para(ForumParaBlock para, YmColors c) {
    final spans = <InlineSpan>[];
    for (final inline in para.inlines) {
      spans.add(_span(inline, c));
    }
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: _base, height: _lineHeight, color: c.text),
        children: spans,
      ),
      textAlign: para.align,
    );
  }

  InlineSpan _span(ForumInline inline, YmColors c) {
    final style = inline.style;
    final index = _seq++;
    final link = inline.isLink && widget.onOpenLink != null;
    final mapped = style.colorHex.isEmpty
        ? const ForumColorResult()
        : forumReadableColor(style.colorHex, c.card);

    // 剧透：作者白字（parse 侧打了位）或与背景过近的颜色（渲染侧判出来）
    if ((style.spoiler || mapped.spoiler)) {
      final key = '${widget.pid}#$index';
      if (!_revealed.contains(key)) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            if (widget.revealed != null) {
              // 外置态：父级（分页容器）落集合并触发重建，本件不自持状态
              widget.onReveal?.call(key);
            } else {
              setState(() => _ownRevealed.add(key));
            }
          };
        _recognizers.add(recognizer);
        return TextSpan(
          text: inline.text,
          // 透明字 + fill 底 = 一坨可点开的遮罩；点开后按正常样式显示
          style: TextStyle(backgroundColor: c.fill, color: Colors.transparent),
          recognizer: recognizer,
        );
      }
    }

    final spanStyle = _styleFor(
      inline,
      c,
      link: link,
      authorColor: mapped.color,
    );
    TapGestureRecognizer? recognizer;
    if (link) {
      recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onOpenLink!(inline.href!);
      _recognizers.add(recognizer);
    }
    if (spanStyle == null && recognizer == null) {
      return TextSpan(text: inline.text);
    }
    return TextSpan(
      text: inline.text,
      style: spanStyle,
      recognizer: recognizer,
    );
  }

  /// 内联样式位 → TextStyle：bold / italic / underline / strike / 字号三档 /
  /// 限幅后的作者色。链接片段 brand 色 + 下划线优先（作者色与链接色冲突时链接胜出）。
  ///
  /// 三档是**相对正文基准的倍率**（原 17/15、13/15），不是绝对值：用户把字号设到 22，
  /// 作者写的「小字」跟着缩到 19 而不是留在 13 上，整章比例才不会打架。
  TextStyle? _styleFor(
    ForumInline inline,
    YmColors c, {
    required bool link,
    Color? authorColor,
  }) {
    final s = inline.style;
    var fontSize = _base;
    if (s.sizeStep > 0) {
      fontSize = _base * 17 / 15;
    } else if (s.sizeStep < 0) {
      fontSize = _base * 13 / 15;
    }

    final decorations = <TextDecoration>[];
    if (s.underline) decorations.add(TextDecoration.underline);
    if (s.strike) decorations.add(TextDecoration.lineThrough);

    Color? color = authorColor;
    Color? decorationColor;
    if (link) {
      color = c.brand;
      if (!decorations.contains(TextDecoration.underline)) {
        decorations.add(TextDecoration.underline);
      }
      decorationColor = c.brand;
    }

    final plain =
        !s.bold &&
        !s.italic &&
        decorations.isEmpty &&
        color == null &&
        !link &&
        s.sizeStep == 0;
    if (plain) return null;

    return TextStyle(
      fontSize: fontSize,
      color: color,
      fontWeight: s.bold ? FontWeight.w700 : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      decoration: decorations.isEmpty
          ? null
          : (decorations.length == 1
                ? decorations.first
                : TextDecoration.combine(decorations)),
      decorationColor: decorationColor,
    );
  }

  Widget _image(ForumImageBlock image, YmColors c) {
    final radius = BorderRadius.circular(YmRadius.inner);
    Widget child = YmForumImage(
      url: image.url,
      fit: BoxFit.contain,
      borderRadius: radius,
      // 解码完高度会从占位变成实图：分页引擎靠这根线发起重排
      onLoaded: widget.onBlockLayoutChanged,
    );
    if (widget.onOpenImage != null) {
      // 图片是「看」的件，按下减淡即可（dim 档），不换底
      child = YmPressable(
        kind: YmPressKind.dim,
        dimOpacity: 0.6,
        radius: radius,
        onTap: () => widget.onOpenImage!(image.url),
        child: child,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        // 文件名式 alt 不算友好：只在有原图链接（包图）时补一行说明
        if (image.caption.isNotEmpty && image.originalUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              image.caption,
              style: TextStyle(
                fontSize: _scaled(_base, YmFont.micro11),
                color: c.text3,
              ),
            ),
          ),
      ],
    );
  }
}

/// 分割线：1px 线 + 上下 10px（块间距 8 + 这里 2）。
class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: c.sep,
    );
  }
}

/// 折叠块（站点 `showcollapse_box`）：默认**展开**，标题一行 small12·w700 可点收起。
/// 嵌套层缩进 12px、最多两级。
class _CollapseView extends StatefulWidget {
  const _CollapseView({
    required this.block,
    required this.level,
    required this.pid,
    required this.base,
    required this.lineHeight,
    this.onOpenLink,
    this.onOpenImage,
    this.onLayoutChanged,
  });

  final ForumCollapseBlock block;
  final int level;
  final String pid;

  /// 正文基准（字号 / 行距）：标题按它等比换算，内容递归时原样传下去。
  final double base;
  final double lineHeight;

  final void Function(String href)? onOpenLink;
  final void Function(String url)? onOpenImage;

  /// 收起 / 展开会改高度：分页引擎靠这根线发起重排。
  final VoidCallback? onLayoutChanged;

  @override
  State<_CollapseView> createState() => _CollapseViewState();
}

class _CollapseViewState extends State<_CollapseView> {
  /// 默认展开（站点上它是作者分段标记，缺省收起会让读者多一次点击）。
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final indent = (widget.level.clamp(0, 2)) * 12.0;
    final body = widget.block.blocks.isEmpty
        ? null
        : YmForumBody(
            blocks: widget.block.blocks,
            pid: widget.pid,
            level: widget.level + 1,
            fontSize: widget.base,
            lineHeight: widget.lineHeight,
            onOpenLink: widget.onOpenLink,
            onOpenImage: widget.onOpenImage,
            onBlockLayoutChanged: widget.onLayoutChanged,
          );

    if (widget.block.title.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(left: indent),
        child: body ?? const SizedBox.shrink(),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          YmPressable(
            kind: YmPressKind.dim,
            dimOpacity: 0.6,
            radius: BorderRadius.circular(YmRadius.chip),
            onTap: () {
              setState(() => _expanded = !_expanded);
              // 高度变了：分页引擎在听（滚动模式没接这根线，回调是空）
              widget.onLayoutChanged?.call();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: c.text3,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.block.title,
                      style: TextStyle(
                        fontSize: _scaled(widget.base, YmFont.small12),
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded && body != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: body),
        ],
      ),
    );
  }
}

/// 附件列表（站点 `ul.post_attlist`）：fill 底小色块，一行一个附件。
/// 图标用工程自有通用文档图标，**不取** `static/image/filetype/*.gif` 网络图。
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.block,
    required this.base,
    this.onOpenLink,
  });

  final ForumAttachmentBlock block;

  /// 正文基准：文件名 / 大小按它等比换算。
  final double base;
  final void Function(String href)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(YmRadius.inner),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < block.items.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _row(context, c, block.items[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, YmColors c, ForumAttachment item) {
    final canOpen = item.href.isNotEmpty && onOpenLink != null;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.insert_drive_file_outlined, size: 18, color: c.text2),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                style: TextStyle(
                  fontSize: _scaled(base, YmFont.body14),
                  fontWeight: FontWeight.w700,
                  color: canOpen ? c.brand : c.text,
                ),
              ),
              if (item.size.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  item.size,
                  style: TextStyle(
                    fontSize: _scaled(base, YmFont.micro11),
                    color: c.text3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    if (!canOpen) return row;
    return YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      radius: BorderRadius.circular(YmRadius.chip),
      onTap: () => onOpenLink!(item.href),
      child: row,
    );
  }
}

/// 引用块（F-11，0.1.22 拍板复用 F-04 点评条视觉语言；0.1.35 随正文件迁到本文件）：
/// fill 底 inner 圆角独立小色块，引用头 small12（作者 w700 text + 时间 text3），
/// 有 pid 时可点跳原楼层（dim 文字动作档，与「回复」同构造）。
class _QuoteBox extends StatelessWidget {
  const _QuoteBox({required this.quote, required this.base, this.onJump});

  final ForumQuote quote;

  /// 正文基准：引用头与引用正文按它等比换算。
  final double base;
  final VoidCallback? onJump;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final header = Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: _scaled(base, YmFont.small12),
          color: c.text2,
        ),
        children: [
          if (quote.author.isNotEmpty)
            TextSpan(
              text: quote.author,
              style: TextStyle(fontWeight: FontWeight.w700, color: c.text),
            ),
          if (quote.time.isNotEmpty)
            TextSpan(
              text: '  发表于 ${quote.time}',
              style: TextStyle(color: c.text3),
            ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        // 卡内嵌块取 fill（fillPlain 是弹层底，不跨层借底——拆件表 C-03）
        color: c.fill,
        borderRadius: BorderRadius.circular(YmRadius.inner),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (quote.author.isNotEmpty || quote.time.isNotEmpty)
            if (onJump != null)
              YmPressable(
                kind: YmPressKind.dim,
                dimOpacity: 0.6,
                radius: BorderRadius.circular(YmRadius.chip),
                onTap: onJump,
                child: Padding(
                  // 与楼层卡「回复」动作同规格的小热区（dim 文字动作档）
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: header,
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: header,
              ),
          if (quote.text.isNotEmpty)
            Text(
              quote.text,
              style: TextStyle(
                fontSize: _scaled(base, YmFont.small12),
                height: 1.62,
                color: c.text2,
              ),
            ),
        ],
      ),
    );
  }
}
