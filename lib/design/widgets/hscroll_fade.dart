import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// 横滑胶囊条：内容超出右缘时叠一层「渐隐」，滚到最右端即收起。
///
/// 口径对齐轨交速查（GuijiaoSucha-DevArea）的 `.hscroll-fade`：
/// - **只在内容确实溢出、且还没滚到最右端时**才出现（溢出就提示「后面还有」，
///   到末端就没必要提示了）—— 溢出靠 `maxScrollExtent > 0.5`、到端靠
///   `pixels >= maxScrollExtent - 1`，两个都是对滚动位置敏感的布尔量；
/// - **覆盖层 + 不挡手势**（原工程 `pointer-events:none`）：在原始工程里它是一层
///   `position:absolute` 的 view，这里对应 `Positioned` + `IgnorePointer`；
/// - **渐隐的实色端取所在容器的底色**：原工程分 `.hscroll-fade`（卡片内 → `--card`）
///   与 `.hscroll-fade.is-page`（页面底 → `--bg`）两档，默认就是页面底这一档（`c.bg`）；
///   放进卡片里时传 `color: c.card`。
///
/// 宽度按原工程 `52rpx ≈ 26px`。行高由胶囊自己决定，渐隐层跟着 `top:0/bottom:0` 撑满。
///
/// 另外补了原工程 `center()` 那件事：**选中项自动滚到可视区中间**（[focusIndex]）。
/// 口径同样是「只在选中变化时滚一次」，滚动位置**不是**受控回灌的 —— 手滑到哪里就停在哪里。
class YmHScrollFade extends StatefulWidget {
  const YmHScrollFade({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
    this.spacing = 8,
    this.fadeWidth = 26,
    this.color,
    this.focusIndex,
    this.focusOnMount = false,
  });

  /// 胶囊本身**不要自带间距**，间隔由 [spacing] 统一插（避免两处各加一半）。
  final List<Widget> children;

  /// 滚动内容的 padding（原工程 `.cat-scroll-inner { padding: 3px }` 这类）。
  final EdgeInsets padding;

  final double spacing;

  /// 渐隐条宽度。原工程 `52rpx`。
  final double fadeWidth;

  /// 渐隐的实色端；不传就取页面底 `c.bg`。放在卡片里请传 `c.card`。
  final Color? color;

  /// 把「选中项的下标」交进来：该值变化时把那一项滚到可视区中间。
  /// 首批渲染不滚（与选站弹层一致：只有用户改选中才动）——
  /// 首开就要定位的场景（图片查看器胶卷）用 [focusOnMount] 显式打开。
  final int? focusIndex;

  /// 首帧后就把 [focusIndex] 那项滚到可视区中间（0.1.22 补：查看器从
  /// 第 18 张打开时胶卷必须直接定位过去，不能停在开头）。
  final bool focusOnMount;

  /// 测试用：渐隐层在树里的标识（不传就没有 key）。
  static const Key fadeKey = ValueKey<String>('ym-hscroll-fade');

  @override
  State<YmHScrollFade> createState() => _YmHScrollFadeState();
}

class _YmHScrollFadeState extends State<YmHScrollFade> {
  final ScrollController _ctrl = ScrollController();

  /// 每颗胶囊一个 GlobalKey，`Scrollable.ensureVisible` 要靠它定位。
  final List<GlobalKey> _itemKeys = <GlobalKey>[];

  bool _overflow = false;
  bool _atEnd = true;
  int? _focus;

  @override
  void initState() {
    super.initState();
    _focus = widget.focusIndex;
    _syncKeys();
    _ctrl.addListener(_sync);
    // 首帧之后才有 maxScrollExtent，溢出判定只能等布局完
    _scheduleSync();
    if (widget.focusOnMount && _focus != null) {
      // 量尺在首帧后才有：定位也等首帧（_centerOnFocus 自己会再排一帧）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _centerOnFocus();
      });
    }
  }

  @override
  void didUpdateWidget(YmHScrollFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncKeys();
    // 胶囊集合变了（切 tab、加载完拿到分类…）宽度会变，重新量一次
    if (oldWidget.children.length != widget.children.length ||
        oldWidget.spacing != widget.spacing ||
        oldWidget.padding != widget.padding) {
      _scheduleSync();
    }
    if (widget.focusIndex != _focus) {
      _focus = widget.focusIndex;
      _centerOnFocus();
    }
  }

  void _syncKeys() {
    while (_itemKeys.length < widget.children.length) {
      _itemKeys.add(GlobalKey());
    }
    if (_itemKeys.length > widget.children.length) {
      _itemKeys.removeRange(widget.children.length, _itemKeys.length);
    }
  }

  /// 选中项居中（原工程 `center()`）：滚到那一项的中心对上可视区中心，
  /// 两端由 `ensureVisible` 自己钳住（原工程是 `Math.max(0, …)`）。
  void _centerOnFocus() {
    final index = _focus;
    if (index == null || index < 0 || index >= _itemKeys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = index < _itemKeys.length ? _itemKeys[index].currentContext : null;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: YmMotion.screen,
        curve: YmMotion.screenCurve,
      );
    });
  }

  @override
  void dispose() {
    _ctrl.removeListener(_sync);
    _ctrl.dispose();
    super.dispose();
  }

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (!mounted || !_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final overflow = pos.maxScrollExtent > 0.5;
    // 没溢出时「到端」恒为真，渐隐不会因为一次抖动闪出来
    final atEnd = !overflow || pos.pixels >= pos.maxScrollExtent - 1;
    if (overflow != _overflow || atEnd != _atEnd) {
      setState(() {
        _overflow = overflow;
        _atEnd = atEnd;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final solid = widget.color ?? YmScope.of(context).colors.bg;
    final rows = <Widget>[];
    for (var i = 0; i < widget.children.length; i++) {
      if (i > 0) rows.add(SizedBox(width: widget.spacing));
      rows.add(KeyedSubtree(key: _itemKeys[i], child: widget.children[i]));
    }

    return Stack(
      children: [
        SingleChildScrollView(
          controller: _ctrl,
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          child: Row(children: rows),
        ),
        if (_overflow && !_atEnd)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: widget.fadeWidth,
            child: IgnorePointer(
              child: DecoratedBox(
                key: YmHScrollFade.fadeKey,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: <Color>[solid, solid.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
