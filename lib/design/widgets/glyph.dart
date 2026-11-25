import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 自绘字形：不随系统字号 / 字体环境变化的矢量图形。
/// 原则：Flutter 里不用文本字符当图标（Text('×') 的墨迹随平台字体漂移，
/// 母本 CSS 的 30px Arial 叉在 Android 上实际走的是 Roboto），一律用图形。
///
/// 口径与资产包 SlateGlyph 对齐：24 viewBox、线宽恒 2px（屏幕像素，不随盒子缩放）、
/// 圆头圆角。返回/chevron/caretDown 三枚直接取自资产包 painter；
/// globe / share / inbox 是百合会自有的三枚扩展（资产包没有对应件，画面按同一套口径画）。
enum YmGlyphKind {
  /// 返回 / 左 chevron（资产包 `SlateGlyphKind.back`）。
  back,

  /// 下 chevron（资产包 `chevronDown`），展开钮用 rotate 转成向上。
  chevronDown,

  /// 实心小三角（资产包 `caretDown`），排序方向指示。
  caretDown,

  /// 地球：详情页「在网页里打开」（宿主扩展）。
  globe,

  /// 分享：网页页右上（宿主扩展）。
  share,

  /// 空托盘：占位页（宿主扩展）。
  inbox,

  /// 选中勾（资产包 SlateGlyphKind.check）：20 画布、实心圆 r9 挖掉对勾。
  check,

  /// 更多三点·正文档（资产包 T18-09 `more`）：24 盒、点径 2.0、跨度 12.0。
  /// 三点字形照抄自资产包，不用字符 `⋯`（基线随字体漂）。
  more,

  /// 更多三点·42 圆钮档（资产包 T18-10 `moreDisc`）：24 盒、点径 3.5、跨度 16.5。
  /// 与 [more] 是两档，不能合并：20/2.0 放进 42 圆钮点径太细。只给菜单触发器用。
  moreDisc,

  /// 下载（资产包 T18-18 `download`，`.glyph-download`）：竖杆 + 双翼 + 托盘。
  ///
  /// path 从上游 `rtgo-flutter-ui` 搬过来，**不 import 包**（第十期拍板）。
  /// 用在章节行右端的「这一章还没存」/「失败可重试」（缓存第一期 1E）。
  download,

  /// 已下载（资产包 T18-18 `downloaded`，`.glyph-downloaded`）：勾 + **同一只**托盘。
  ///
  /// 与 [download] 的墨迹宽同为 16.4，并排时左右边与下缘对齐 —— 所以两者换用时
  /// 行内不会左右跳一下。
  downloaded,

  /// 排序·箭头朝上（资产包 T18-13 `sortAsc`，`.glyph-sort-asc`）：
  /// 左侧竖杆 + 朝上的箭头 + 右侧三条**等长**横线（等长是刻意的：长短递减在本
  /// 设计语言里读作「数据量」，等长才读作「列表顺序」）。
  sortAsc,

  /// 排序·箭头朝下（资产包 T18-14 `sortDesc`，`.glyph-sort-desc`）：
  /// 与 [sortAsc] 上下镜像 —— 三条横线逐值相同，只有箭头翻向下。
  sortDesc,
}

class YmGlyph extends StatelessWidget {
  const YmGlyph({
    super.key,
    required this.kind,
    this.size = 20,
    this.color,
    this.strokeWidth = 2,
    this.rotate = 0,
  });

  final YmGlyphKind kind;

  /// 画布边长（≠墨迹大小）。
  final double size;
  final Color? color;

  /// 屏幕像素线宽（与母本 CSS border 2px 同语义）。
  final double strokeWidth;
  final double rotate;

  @override
  Widget build(BuildContext context) {
    final glyphColor = color ?? YmScope.of(context).colors.textStrong;
    return Transform.rotate(
      angle: rotate,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _YmGlyphPainter(
            kind: kind,
            color: glyphColor,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }

  /// T18-04 线路条/线路网格的展开·收起钮：母本 `.line-expand-btn` 的 34 圆里那枚
  /// `.line-expand-arrow`。**14 盒**，屏幕线宽恒 2px，墨迹 9.0×5.5。
  ///
  /// 出处：真值源 rtgo-flutter 2026-11-09 具名档 `SlateGlyph.lineExpandChevron`
  /// （chevronDown / size 14 / strokeWidth 2）。展开与收起是同一枚件，只差 rotate π。
  const YmGlyph.lineExpandChevron({super.key, this.color, this.rotate = 0})
    : kind = YmGlyphKind.chevronDown,
      size = 14,
      strokeWidth = 2;

  /// 正文裸三点（资产包 T18-09）：20 盒，点径 2.0 / 跨度 12.0。
  /// 24 viewBox 里三个 r=1.2 的圆，盒子缩到 20 即得 2.0 点径。
  const YmGlyph.more({super.key, this.color, this.rotate = 0})
    : kind = YmGlyphKind.more,
      size = 20,
      strokeWidth = 2;

  /// 顶栏 42 圆钮里的三点（资产包 T18-10）：24 盒，点径 3.5 / 跨度 16.5。
  /// 圆钮档专用；正文 / 底栏继续用 [YmGlyph.more]。
  const YmGlyph.moreDisc({super.key, this.color, this.rotate = 0})
    : kind = YmGlyphKind.moreDisc,
      size = 24,
      strokeWidth = 2;
}

/// 排序胶囊行尾的方向三角。三角本身来自资产包 caretDown，
/// 升序转 180°；盒 10 时墨迹约 7.1×6.7dp。
class YmSortCaret extends StatelessWidget {
  const YmSortCaret({
    super.key,
    required this.desc,
    this.color,
    this.size = 10,
  });

  final bool desc;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    // 光学对齐：caretDown 的墨迹在盒子里偏上 1.83dp（Noto 与 13/1.5 文字同排实测）。
    // 升序是整枚旋转 180°，墨迹会跟着翻到下方，补偿方向必须同时翻转，否则反向时偏低。
    return Transform.translate(
      offset: Offset(0, desc ? 2 : -2),
      child: YmGlyph(
        kind: YmGlyphKind.caretDown,
        size: size,
        color: color,
        rotate: desc ? 0 : math.pi,
      ),
    );
  }
}

class _YmGlyphPainter extends CustomPainter {
  _YmGlyphPainter({
    required this.kind,
    required this.color,
    required this.strokeWidth,
  });

  final YmGlyphKind kind;
  final Color color;
  final double strokeWidth;

  /// 各字形的原生 viewBox；[vbStroke] 非空表示线宽按 **viewBox 单位**走。
  ({double w, double h, double? vbStroke}) get _metrics => switch (kind) {
    // 母本 .check-glyph（wxss:143）viewBox 0 0 20 20，stroke-width 2.4。
    YmGlyphKind.check => (w: 20, h: 20, vbStroke: 2.4),
    _ => (w: 24, h: 24, vbStroke: null),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final m = _metrics;
    final scale = math.min(size.width / m.w, size.height / m.h);
    canvas.save();
    canvas.translate(
      (size.width - m.w * scale) / 2,
      (size.height - m.h * scale) / 2,
    );
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      // 线宽是**屏幕像素**，不随画布缩放（与母本 CSS border 的 2px 同语义）。
      ..strokeWidth = m.vbStroke != null ? m.vbStroke! : strokeWidth / scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (kind) {
      case YmGlyphKind.back:
        canvas.drawPath(
          Path()
            ..moveTo(15, 5)
            ..lineTo(8, 12)
            ..lineTo(15, 19),
          stroke,
        );
      case YmGlyphKind.chevronDown:
        canvas.drawPath(
          Path()
            ..moveTo(6, 9)
            ..lineTo(12, 15)
            ..lineTo(18, 9),
          stroke,
        );
      case YmGlyphKind.caretDown:
        // 资产包 caretDown：墨迹 17.14×16.08（24 画布），下缘留 7.78。
        canvas.drawPath(
          Path()
            ..moveTo(3.43, 0.14)
            ..lineTo(20.57, 0.14)
            ..lineTo(12, 16.22)
            ..close(),
          fill,
        );
      case YmGlyphKind.globe:
        canvas.drawCircle(const Offset(12, 12), 8.2, stroke);
        canvas.drawLine(const Offset(3.8, 12), const Offset(20.2, 12), stroke);
        // 经线：半个椭圆的两段弧。
        canvas.drawPath(
          Path()
            ..moveTo(12, 3.8)
            ..cubicTo(7.2, 6.4, 7.2, 17.6, 12, 20.2)
            ..cubicTo(16.8, 17.6, 16.8, 6.4, 12, 3.8),
          stroke,
        );
      case YmGlyphKind.share:
        // 向上箭头 + 开口盒。
        canvas.drawLine(const Offset(12, 4.2), const Offset(12, 14.5), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(8.4, 7.8)
            ..lineTo(12, 4.2)
            ..lineTo(15.6, 7.8),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(6, 11.5)
            ..lineTo(6, 19.5)
            ..lineTo(18, 19.5)
            ..lineTo(18, 11.5),
          stroke,
        );
      case YmGlyphKind.check:
        // 实心圆 r9 里**挖掉**对勾（不是画白勾）。母本 60 画布 × scale(.3333)
        // 是给位图遮罩做抗锯齿的，矢量绘制不需要。
        canvas.saveLayer(const Rect.fromLTWH(0, 0, 20, 20), Paint());
        canvas.drawCircle(const Offset(10, 10), 9, fill);
        canvas.drawPath(
          Path()
            ..moveTo(5.9, 10.3)
            ..lineTo(8.9, 13.3)
            ..lineTo(14.3, 7.4),
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..blendMode = BlendMode.clear,
        );
        canvas.restore();
      case YmGlyphKind.more:
        // T18-09（资产包 `.glyph-more`）：24 viewBox 三个 r=1.2 实心点，
        // 圆心 x=6/12/18、y=12。20 盒 ⇒ 点径 2dp、墨迹跨度 12dp。
        for (final x in <double>[6, 12, 18]) {
          canvas.drawCircle(Offset(x, 12), 1.2, fill);
        }
      case YmGlyphKind.moreDisc:
        // T18-10（资产包 `.glyph-more-disc`）：24 viewBox 三个 r=1.75 实心点，
        // 圆心 x=5.5/12/18.5（pitch 6.5）。24 盒 ⇒ 点径 3.5 / 跨度 16.5，
        // 占 42 圆钮直径 39.3%，与返回箭头同面积。只给菜单触发器用。
        for (final x in <double>[5.5, 12, 18.5]) {
          canvas.drawCircle(Offset(x, 12), 1.75, fill);
        }
      case YmGlyphKind.download:
        // T18-18：竖杆 4.6→13.3、双翼 8.1/15.9 收在 13.3，下面叠托盘。
        canvas.drawLine(const Offset(12, 4.6), const Offset(12, 13.3), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(8.1, 9.4)
            ..lineTo(12, 13.3)
            ..lineTo(15.9, 9.4),
          stroke,
        );
        canvas.drawPath(_fileTray(), stroke);
      case YmGlyphKind.downloaded:
        // T18-18：勾 7.7,9.0 → 11.2,12.5 → 16.7,5.2，托盘与 download 同一只。
        canvas.drawPath(
          Path()
            ..moveTo(7.7, 9.0)
            ..lineTo(11.2, 12.5)
            ..lineTo(16.7, 5.2),
          stroke,
        );
        canvas.drawPath(_fileTray(), stroke);
      case YmGlyphKind.inbox:
        // 托盘：盒 + 内凹的托盘口。
        canvas.drawPath(
          Path()
            ..moveTo(4, 5.5)
            ..lineTo(4, 18.5)
            ..lineTo(20, 18.5)
            ..lineTo(20, 5.5)
            ..close(),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(4, 13)
            ..lineTo(8.6, 13)
            ..lineTo(10.2, 15.4)
            ..lineTo(13.8, 15.4)
            ..lineTo(15.4, 13)
            ..lineTo(20, 13),
          stroke,
        );
      case YmGlyphKind.sortAsc:
        // T18-13：竖杆 x 6.9（4.8→19.2），两翼端点 4.65 / 9.15 落在 y 7.05；
        // 右侧三条等长横线 y 6.5 / 12 / 17.5、x 13.5→19.5。
        canvas.drawPath(
          Path()
            ..moveTo(6.9, 19.2)
            ..lineTo(6.9, 4.8)
            ..moveTo(4.65, 7.05)
            ..lineTo(6.9, 4.8)
            ..lineTo(9.15, 7.05)
            ..moveTo(13.5, 6.5)
            ..lineTo(19.5, 6.5)
            ..moveTo(13.5, 12)
            ..lineTo(19.5, 12)
            ..moveTo(13.5, 17.5)
            ..lineTo(19.5, 17.5),
          stroke,
        );
      case YmGlyphKind.sortDesc:
        // T18-14：与 [sortAsc] 同一件的上下镜像（杆 4.8→19.2，两翼端点 4.65 / 9.15
        // 落在 y 16.95）。改横线要两枚一起改。
        canvas.drawPath(
          Path()
            ..moveTo(6.9, 4.8)
            ..lineTo(6.9, 19.2)
            ..moveTo(4.65, 16.95)
            ..lineTo(6.9, 19.2)
            ..lineTo(9.15, 16.95)
            ..moveTo(13.5, 6.5)
            ..lineTo(19.5, 6.5)
            ..moveTo(13.5, 12)
            ..lineTo(19.5, 12)
            ..moveTo(13.5, 17.5)
            ..lineTo(19.5, 17.5),
          stroke,
        );
    }

    canvas.restore();
  }

  /// T18-18 的托盘（两者共用，照抄上游 `_fileTray()`）：左壁 4.8,13.9→16.9、
  /// 两个 r1.9 圆角过渡到底边 18.8，右壁回到 13.9。墨迹宽 = 14.4 + 线宽 2 = 16.4。
  Path _fileTray() => Path()
    ..moveTo(4.8, 13.9)
    ..lineTo(4.8, 16.9)
    ..quadraticBezierTo(4.8, 18.8, 6.7, 18.8)
    ..lineTo(17.3, 18.8)
    ..quadraticBezierTo(19.2, 18.8, 19.2, 16.9)
    ..lineTo(19.2, 13.9);

  @override
  bool shouldRepaint(_YmGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// painter 字形：不随系统字号 / 字体环境变化的矢量图形。
///
/// 墨迹标准与返回钮（26 盒，墨迹高 13.0px、线宽 2px）对齐，
/// 与轨交 SlateCloseButton 完全同规格：
/// × 路径在 24 单位 viewBox 里占 10/24，圆头笔帽再各延出半线宽，
/// 竖向墨迹 = 10·(size/24) + strokeWidth ⇒ size 26 / strokeWidth 2 → 12.8px。
class YmCloseGlyph extends StatelessWidget {
  const YmCloseGlyph({
    super.key,
    this.size = 26,
    this.color,
    this.strokeWidth = 2,
  });

  /// 画布边长（≠墨迹大小，墨迹见上方公式）。
  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final glyphColor = color ?? YmScope.of(context).colors.textStrong;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CloseGlyphPainter(
          color: glyphColor,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _CloseGlyphPainter extends CustomPainter {
  _CloseGlyphPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 24;
    canvas.save();
    canvas.translate(
      (size.width - 24 * scale) / 2,
      (size.height - 24 * scale) / 2,
    );
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      // strokeWidth 是**屏幕像素**，不随画布缩放（与母本 CSS border 的 2px 同语义）。
      ..strokeWidth = strokeWidth / scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawLine(const Offset(7, 7), const Offset(17, 17), stroke);
    canvas.drawLine(const Offset(17, 7), const Offset(7, 17), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CloseGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}
