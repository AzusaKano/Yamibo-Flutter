import 'package:flutter/material.dart';

import '../../data/reader_prefs.dart';
import '../../data/models.dart';
import '../../data/cn.dart';
import '../theme.dart';
import '../tokens.dart';
import '../pressable.dart';
import 'button.dart';
import 'chip.dart';
import 'glyph.dart';

/// 底部弹层：380ms 进场 / 300ms 退场，遮罩 200ms；点击遮罩关闭。
///
/// 动效口径（对齐 uni 资产包 `picker-panel-in` 的三段骨架，两处改进）：
/// ① 面板**整块从底部推上来**（115% 自身高度），进场不淡入 —— 淡入会读成「浮上来」，没有推上来的重量；
/// ② 62% 处冲到目标位略上方，再用短缓收回落位（尾段轻微超出回弹）；
/// ③ 遮罩 200ms 先到位，不跟着面板一起磨 380ms。
Future<T?> showYmSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext) builder,
}) {
  final colors = YmScope.of(context).colors;
  return Navigator.of(context).push<T>(
    PageRouteBuilder<T>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      barrierLabel: '关闭',
      transitionDuration: YmMotion.sheetIn,
      reverseTransitionDuration: YmMotion.sheetOut,
      pageBuilder: (context, animation, secondary) =>
          _YmSheetShell(animation: animation, child: builder(context)),
      transitionsBuilder: (context, animation, secondary, child) =>
          _YmSheetMask(animation: animation, color: colors.mask, child: child),
    ),
  );
}

/// 遮罩层：垫在内容下面，默认 200ms 淡入 / 淡出。
class _YmSheetMask extends StatelessWidget {
  const _YmSheetMask({
    required this.animation,
    required this.color,
    required this.child,
    this.span = YmMotion.maskSpan,
  });

  final Animation<double> animation;
  final Color color;
  final Widget child;

  /// 遮罩走完整渐变的时长占整段进场的比例。
  final double span;

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(
      parent: animation,
      curve: Interval(0, span, curve: Curves.easeOut),
      reverseCurve: Interval(0, span, curve: Curves.easeIn),
    );
    return Stack(
      children: [
        Positioned.fill(
          // 让点击穿透到路由 barrier，由它关闭弹层。
          child: IgnorePointer(
            // 只动 opacity：遮罩色自带 .45 透明度，别再改 alpha（会把背景刷成实色）。
            child: FadeTransition(
              opacity: fade,
              child: ColoredBox(color: color),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 弹层落位：从下方 `1.15 ×` 自身高度处整块推进来（仅弹层用；对话框走 [_YmDialogLift]）。
class _YmSheetSlide extends StatelessWidget {
  const _YmSheetSlide({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  /// 进场起始位移：uni `picker-panel-in` 的 115%。
  static const double _inFrom = 1.15;

  /// 退场位移：uni `picker-panel-out` 只写 `translateY(100%)` —— 滑动距离比进场短 15%，
  /// 但同样 300ms，读起来更利落（进场那多出的 15% 是为了藏住圆角与投影）。
  static const double _outFrom = 1.0;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: YmMotion.sheetInCurve,
      reverseCurve: YmMotion.sheetOutReverse,
    );
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) {
        final from = animation.status == AnimationStatus.reverse
            ? _outFrom
            : _inFrom;
        return FractionalTranslation(
          translation: Offset(0, from * (1 - curved.value)),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// 对话框的位移：从屏幕底部滑进来 / 滑出去（整块滑，不是只浮 12px）。
/// 卡片不淡入 —— 起点完全在屏外，第一帧看不见就够了。
class _YmDialogSlide extends StatelessWidget {
  const _YmDialogSlide({
    required this.animation,
    required this.extraPx,
    required this.child,
  });

  final Animation<double> animation;

  /// 面板离屏底还有 16px + 安全区，光滑自身高度是滑不干净的。
  final double extraPx;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: YmMotion.dialogCurve,
      reverseCurve: YmMotion.sheetOutReverse,
    );
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) {
        final k = 1 - curved.value;
        return Transform.translate(
          offset: Offset(0, extraPx * k),
          child: FractionalTranslation(translation: Offset(0, k), child: child),
        );
      },
      child: child,
    );
  }
}

class _YmSheetShell extends StatelessWidget {
  const _YmSheetShell({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final h = MediaQuery.sizeOf(context).height;
    // 取 viewPadding（padding 在被 SafeArea 消费过的分支里偏小，资产包 2026-10-28 实机修复）。
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: h * 0.88),
        child: _YmSheetSlide(
          animation: animation,
          // 必须有 Material 祖先：否则 Text 会落到 WidgetsApp 的“错误样式”
          // （红字 + 黄色双下划线），弹层里所有文字都会带黄线。
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: double.infinity,
              // 母本 padding-bottom: max(18px, env(safe-area-inset-bottom))；
              // 写成 safe + 18 会让全面屏机型多出一整行死白。
              padding: EdgeInsets.fromLTRB(
                14,
                18,
                14,
                safeBottom > 18 ? safeBottom : 18,
              ),
              decoration: BoxDecoration(
                color: c.sheet,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(YmRadius.card),
                ),
                boxShadow: YmShadows.sheet,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class YmSheetHeader extends StatelessWidget {
  const YmSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: c.title21),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: c.micro11),
                ],
              ],
            ),
          ),
          trailing ?? const YmCloseButton(),
        ],
      ),
    );
  }
}

/// 42×42 圆形关闭钮：与返回钮同尺寸同语言（card 底、border 描边、pop 投影）。
/// 字形是 painter 画的「×」（YmCloseGlyph），不再是 Arial 30px 文本字符。
class YmCloseButton extends StatelessWidget {
  const YmCloseButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    // 与 YmCircleButton / SlateCloseButton 同构：外层 SizedBox(42) 硬约束尺寸，
    // 描边/投影走 YmPressable 的 border/boxShadow（缩放层内），
    // 按下时整个 42 圆一起下沉——原来挂在缩放层外的外层 Container 上，圆环不缩。
    return SizedBox(
      width: 42,
      height: 42,
      child: YmPressable(
        kind: YmPressKind.neutral,
        baseColor: c.card,
        radius: BorderRadius.circular(21),
        border: Border.all(color: c.border),
        boxShadow: YmShadows.pop,
        onTap: onTap ?? () => Navigator.of(context).maybePop(),
        child: const Center(child: YmCloseGlyph()),
      ),
    );
  }
}

Future<bool?> showYmConfirm(
  BuildContext context, {
  required String title,
  String? content,
  String confirmText = '确定',
  String cancelText = '取消',
  bool danger = false,
  bool onlyConfirm = false,
}) {
  final colors = YmScope.of(context).colors;
  return Navigator.of(context).push<bool>(
    PageRouteBuilder<bool>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      barrierLabel: '关闭',
      transitionDuration: YmMotion.dialogIn,
      reverseTransitionDuration: YmMotion.dialogOut,
      pageBuilder: (ctx, animation, secondary) {
        final bottom = MediaQuery.paddingOf(ctx).bottom;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
            // 对话框：整块从底部滑进来 / 滑出去（不淡入、不缩放）。
            child: _YmDialogSlide(
              animation: animation,
              extraPx: 16 + bottom,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    color: colors.card,
                    borderRadius: BorderRadius.circular(YmRadius.card),
                    // 母本 `box-shadow:0 10px 30px rgba(23,27,40,.16)`（.16 = 0x29）。
                    boxShadow: const [
                      BoxShadow(
                        offset: Offset(0, 10),
                        blurRadius: 30,
                        color: Color(0x29171B28),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // T10-05 .snp-head：pad 0 4 12；21/800/1.25。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                        child: Text(
                          title,
                          style: colors.title21.copyWith(height: 1.25),
                        ),
                      ),
                      if (content != null)
                        // T21-02 .snp-body：pad 0 4 20；14 / 1.6 / text-2。
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
                          child: Text(
                            content,
                            style: colors.body14Regular.copyWith(
                              color: colors.text2,
                              height: 1.6,
                            ),
                          ),
                        ),
                      // T06-06 .dtp-actions：gap 10 / pad 2 4 0。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
                        child: Row(
                          children: [
                            if (!onlyConfirm) ...[
                              Expanded(
                                child: YmDialogButton(
                                  label: cancelText,
                                  onTap: () => Navigator.of(ctx).pop(false),
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: YmDialogButton(
                                label: confirmText,
                                primary: true,
                                danger: danger,
                                onTap: () => Navigator.of(ctx).pop(true),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionsBuilder: (context, animation, secondary, child) =>
          _YmSheetMask(
            animation: animation,
            color: colors.mask,
            span: YmMotion.dialogMaskSpan,
            child: child,
          ),
    ),
  );
}

/// 只有一个「知道了」的提示框。
///
/// 失败 / 已完成这类「看一眼就行」的场景用它 —— 别用 [showYmConfirm]，
/// 那个多一个「取消」按钮，会让人以为这里还有的选。
Future<void> showYmAlert(
  BuildContext context, {
  required String title,
  String? content,
  String confirmText = '知道了',
}) async {
  await showYmConfirm(
    context,
    title: title,
    content: content,
    confirmText: confirmText,
    onlyConfirm: true,
  );
}

class YmTocSheet extends StatefulWidget {
  const YmTocSheet({
    super.key,
    required this.chapters,
    this.currentId,
    required this.onPick,
    this.title = '目录',
    this.subtitle,
    this.unit = '章',
    this.topAction,
  });

  final List<YmChapterRef> chapters;
  final String? currentId;
  final ValueChanged<YmChapterRef> onPick;
  final String title;
  final String? subtitle;
  final String unit;

  /// 可选的顶部动作位（论坛作品帖的「继续阅读 第 X 章」）。
  /// 小说侧不传 ⇒ 行为与外观零变化。
  final Widget? topAction;

  @override
  State<YmTocSheet> createState() => _YmTocSheetState();
}

class _YmTocSheetState extends State<YmTocSheet> {
  late final List<Object> _rows;
  late final ScrollController _controller;
  bool _controllerReady = false;

  /// 两类行各自定高：分卷名 = 上下 padding + 12·1.5 行高；章节 = 14×2 + 14·1.45 行高。
  /// 字号乘系统缩放，itemExtentBuilder 给出的 extent 才与实际渲染一致。
  double _extent(Object row, int i, TextScaler scaler) => row is String
      ? (i == 0 ? 2.0 : 16.0) + 6 + scaler.scale(YmFont.small12) * 1.5
      : 28 + scaler.scale(YmFont.body14) * 1.45;

  /// 当前章在视口内时保持 0；不在视口内才居中定位。
  double _initialOffset(TextScaler scaler, double viewport) {
    if (widget.currentId == null) return 0;
    final target = _rows.indexWhere(
      (r) => r is YmChapterRef && r.id == widget.currentId,
    );
    if (target < 0) return 0;
    var before = 0.0;
    for (var i = 0; i < target; i++) {
      before += _extent(_rows[i], i, scaler);
    }
    final extent = _extent(_rows[target], target, scaler);
    if (before + extent <= viewport) return 0;
    return (before - (viewport - extent) / 2)
        .clamp(0.0, double.infinity)
        .toDouble();
  }

  @override
  void initState() {
    super.initState();
    final volumes = <YmVolume>[];
    for (final ch in widget.chapters) {
      final name = ch.volume.isEmpty ? '' : ch.volume;
      if (volumes.isEmpty || volumes.last.name != name) {
        volumes.add(YmVolume(name: name, chapters: [ch]));
      } else {
        volumes.last.chapters.add(ch);
      }
    }
    _rows = <Object>[];
    for (final v in volumes) {
      if (v.name.isNotEmpty) _rows.add(v.name);
      _rows.addAll(v.chapters);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 只能在依赖就绪后读；控制器只建这一次，之后滚动交还用户。
    if (_controllerReady) return;
    _controllerReady = true;
    _controller = ScrollController(
      initialScrollOffset: _initialOffset(
        MediaQuery.textScalerOf(context),
        MediaQuery.sizeOf(context).height * 0.66,
      ),
    );
  }

  @override
  void dispose() {
    if (_controllerReady) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final scaler = MediaQuery.textScalerOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        YmSheetHeader(
          title: '${widget.title} · 共 ${widget.chapters.length} ${widget.unit}',
          subtitle: widget.subtitle,
        ),
        if (widget.topAction != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 2, 15, 10),
            child: widget.topAction!,
          ),
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.66,
          child: ListView.builder(
            controller: _controller,
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: _rows.length,
            itemExtentBuilder: (i, _) => _extent(_rows[i], i, scaler),
            itemBuilder: (context, i) {
              final row = _rows[i];
              // 分卷名在卡外（uni `.toc-vol.in-sheet`），章节按连续段各自成卡。
              if (row is String) {
                return Padding(
                  padding: EdgeInsets.fromLTRB(15, i == 0 ? 2 : 16, 15, 6),
                  child: Text(
                    row,
                    // 分卷名＝卡外分组标题：资产包 SlateSettingsGroupTitle 声明
                    // 12·650 → snap w700（composites/settings.dart）。原先 w800 高一档。
                    style: c.small12.copyWith(
                      color: c.text2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              }
              final ch = row as YmChapterRef;
              final active = ch.id == widget.currentId;
              final first = i == 0 || _rows[i - 1] is String;
              final last = i == _rows.length - 1 || _rows[i + 1] is String;
              final shape = BorderRadius.vertical(
                top: Radius.circular(first ? YmRadius.panel : 0),
                bottom: Radius.circular(last ? YmRadius.panel : 0),
              );
              return YmPressable(
                kind: YmPressKind.row,
                radius: shape,
                onTap: () => widget.onPick(ch),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: active ? c.brandTint : c.cardLift,
                    borderRadius: shape,
                    border: last
                        ? null
                        : Border(bottom: BorderSide(color: c.borderWeak)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          ch.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: c.body14Regular.copyWith(
                            color: active ? c.brandInk : c.text,
                            // 长清单的**内容行档 500**（不是"中间值"）：
                            // 资产里密集内容行用的就是 500 —— `.chip` 13/500、
                            // 详情页预览节点的线路名 sub13·w500、事实行 w500
                            //（`test/type_weight_test.dart` 写明「实机裁决取 500」）。
                            // 这里是 290 行连读的目录：400 整屏发飘、视觉很花；
                            // 700 会糊成一片黑块，还把"当前章"压平。500 是两者之间唯一稳的档。
                            // 当前章仍靠 brandTint 底 + brandInk 色跳出，不再叠字重。
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class YmReaderSettingsSheet extends StatelessWidget {
  const YmReaderSettingsSheet({super.key, this.showTraditional = true});

  /// 是否给出「字形」（简体 / 繁體）这一组。
  ///
  /// 论坛阅读器传 `false`：论坛正文是块结构 + 内联片段，逐片段转简繁会改掉作者原文
  /// （台版引文会被转坏），所以那边不提供这个开关，留着一个点了没反应的档更糟。
  /// 小说侧不传 ⇒ 面板与原来完全一致。
  final bool showTraditional;

  /// 预览样例（作者本人提供的原文，勿改写）。55 字，17px 下约 3 行，正好撑满预览卡而不撑高面板；
  /// 含 11 个简繁差异字（陽與遠處綿鬱蔥綠陳鄉間），切「繁體」时变化看得清。
  static const _sample =
      '阳光照射在路旁的田野与远处延绵的山峰上，映照出郁郁葱葱的绿色。'
      '陈小佑手扶草帽，眺望着远方，慢慢走在乡间小道上。';

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return AnimatedBuilder(
      animation: readerPrefs,
      builder: (context, _) {
        final prefs = readerPrefs;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const YmSheetHeader(title: '阅读设置'),
              const SizedBox(height: 12),
              // 翻页模式（第十五期）：上下滚动 = 历史行为（默认），左右翻页 =
              // 整屏分页。两个文字阅读器共用这份偏好，一处切换处处生效。
              Text(
                '翻页模式',
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w800,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  YmChip(
                    style: YmChipStyle.pill,
                    pressKind: YmPressKind.solid,
                    label: '上下滚动',
                    active: !prefs.paged,
                    onTap: () => prefs.setPaged(false),
                  ),
                  const SizedBox(width: 8),
                  YmChip(
                    style: YmChipStyle.pill,
                    pressKind: YmPressKind.solid,
                    label: '左右翻页',
                    active: prefs.paged,
                    onTap: () => prefs.setPaged(true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 面板内分组标题（字号/行距/字形，下方同档两处）：13·800 是资产包已声明的组合
              // ——分类面板标题「13 / 800 / --text-2」（composites/category_bar.dart），故保留。
              Text(
                '字号',
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w800,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final f in YmReaderPrefs.fonts) ...[
                    YmChip(
                      style: YmChipStyle.pill,
                      pressKind: YmPressKind.solid,
                      label: f.toInt().toString(),
                      active: prefs.fontSize == f,
                      onTap: () => prefs.setFontSize(f),
                    ),
                    if (f != YmReaderPrefs.fonts.last) const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '行距',
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w800,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final l in YmReaderPrefs.lines) ...[
                    YmChip(
                      style: YmChipStyle.pill,
                      pressKind: YmPressKind.solid,
                      label: l.toStringAsFixed(1),
                      active: prefs.lineHeight == l,
                      onTap: () => prefs.setLineHeight(l),
                    ),
                    if (l != YmReaderPrefs.lines.last) const SizedBox(width: 8),
                  ],
                ],
              ),
              if (showTraditional) ...[
                const SizedBox(height: 16),
                Text(
                  '字形',
                  style: TextStyle(
                    fontSize: YmFont.sub13,
                    fontWeight: FontWeight.w800,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    YmChip(
                      style: YmChipStyle.pill,
                      pressKind: YmPressKind.solid,
                      label: '简体',
                      active: !prefs.traditional,
                      onTap: () => prefs.setTraditional(false),
                    ),
                    const SizedBox(width: 8),
                    YmChip(
                      style: YmChipStyle.pill,
                      pressKind: YmPressKind.solid,
                      label: '繁體',
                      active: prefs.traditional,
                      onTap: () => prefs.setTraditional(true),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(YmRadius.box),
                ),
                child: Text(
                  // 不给字形开关时，预览就按原样显示（与论坛正文的做法一致）
                  readerText(_sample, showTraditional && prefs.traditional),
                  style: TextStyle(
                    fontSize: prefs.fontSize,
                    height: prefs.lineHeight,
                    color: c.text,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
