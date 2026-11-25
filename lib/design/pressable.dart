import 'package:flutter/material.dart';

import '../dev/metrics.dart';
import 'theme.dart';
import 'tokens.dart';

/// 按压五档，与资产包同一套词汇（母本 `hover-class` 家族）：
///  - [neutral] 母本 `press` → 换底 + scale(.96)
///  - [solid]   母本 `press-scale` → 只 scale(.96)
///  - [row]     母本 `press-flat` → 只换底，不缩放
///  - [none]    母本没有 hover-class 的裸文字钮 → 无任何视觉反馈
///  - [dim]     `opacity:.55/.6` 档 → 整块淡化，底色与尺寸不动
///
/// 反馈在 pointerDown 的那一帧就切到按下态；250ms 只是视觉过渡，不是响应延迟。
enum YmPressKind { neutral, solid, row, none, dim }

/// 内层按压的「认领」信号：沿祖先链上冒，告诉每个外层 [YmPressable]
/// 「这一次按下由我负责，你别亮」。对应母本 `hover-stop-propagation`。
class _PressTakeover extends Notification {
  const _PressTakeover();
}

class YmPressable extends StatefulWidget {
  const YmPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    required this.kind,
    this.baseColor,
    this.pressedColor,
    this.radius,
    this.border,
    this.boxShadow,
    this.enabled = true,
    this.semanticLabel,
    this.stopPropagation = false,
    this.dimOpacity = 0.55,
    this.probe = true,
    this.probeKey = 'press',
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 按压档位。**必填，没有默认值**：给默认值等于让调用点不判断也能量出一档，
  /// 历史上按压错配全部来自「不传就走默认」。
  final YmPressKind kind;
  final Color? baseColor;
  final Color? pressedColor;
  final BorderRadius? radius;
  final Border? border;
  final List<BoxShadow>? boxShadow;

  /// 禁用：不响应按压与点击、不进 Semantics 的可点态。
  final bool enabled;
  final String? semanticLabel;

  /// 按下时**阻断祖先的按压反馈**，只亮自己（母本 `hover-stop-propagation`）。
  final bool stopPropagation;

  /// [YmPressKind.dim] 按下时的透明度（母本两处口径 .55 / .6）。
  final double dimOpacity;

  final bool probe;
  final String probeKey;

  @override
  State<YmPressable> createState() => _YmPressableState();
}

class _YmPressableState extends State<YmPressable> {
  static const double _slop = 8;

  bool _down = false;
  Offset? _origin;
  double _travel = 0;

  /// 本次按下是否已被**后代**认领。指针事件按命中路径「先深后浅」派发，
  /// 内层的 onPointerDown 先跑并 dispatch 认领信号，外层随后读到 true。
  bool _takenOverByChild = false;

  void _setDown(bool value) {
    if (!widget.enabled || _down == value) return;
    if (value && widget.probe) {
      ymBeginProbe(widget.probeKey, '按下 → 该帧完成');
    }
    setState(() => _down = value);
  }

  void _handlePointerDown(PointerDownEvent event) {
    final claimed = _takenOverByChild;
    _takenOverByChild = false;
    if (claimed) return;
    if (widget.stopPropagation) {
      const _PressTakeover().dispatch(context);
    }
    _origin = event.position;
    _travel = 0;
    _setDown(true);
  }

  void _cancelIfMoved(PointerMoveEvent event) {
    if (!_down) return;
    final origin = _origin ??= event.position;
    _travel += (event.position - origin).distance;
    if (_travel > _slop) _setDown(false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    final pressed = _down;
    final scale =
        pressed &&
            widget.kind != YmPressKind.row &&
            widget.kind != YmPressKind.none &&
            widget.kind != YmPressKind.dim
        ? YmMotion.pressScale
        : 1.0;
    final pressColor = widget.pressedColor ?? colors.press;
    // ⚠ 静止底色**不能**用 Colors.transparent：它是「透明黑」(0x00000000)，
    // 而 Color.lerp 是**逐通道**插值 ⇒ 中途会经过「半透明深灰」，按下先灰一下再转品牌色，
    // 松手再灰一次（用户实测反馈）。起点取同一个按压色的 0 alpha，就只剩透明度在变。
    final restColor = widget.baseColor ?? pressColor.withValues(alpha: 0);
    final background =
        pressed &&
            widget.kind != YmPressKind.solid &&
            widget.kind != YmPressKind.none &&
            widget.kind != YmPressKind.dim
        ? pressColor
        : restColor;
    // `.station-nav-hover{opacity:.55}` 是 hover-class 直接换值、没有过渡，
    // 所以这里用 Opacity 而不是 AnimatedOpacity。
    final dimmed = widget.kind == YmPressKind.dim && pressed;

    Widget result = NotificationListener<_PressTakeover>(
      // 返回 false：继续向上冒泡，让整条祖先链都跳过（卡片里可能还套着卡片）。
      onNotification: (_) {
        _takenOverByChild = true;
        return false;
      },
      child: Listener(
        onPointerDown: widget.enabled ? _handlePointerDown : null,
        onPointerMove: widget.enabled ? _cancelIfMoved : null,
        onPointerUp: widget.enabled ? (_) => _setDown(false) : null,
        onPointerCancel: widget.enabled ? (_) => _setDown(false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          onLongPress: widget.enabled ? widget.onLongPress : null,
          child: Opacity(
            opacity: dimmed ? widget.dimOpacity : 1,
            child: AnimatedScale(
              scale: scale,
              duration: YmMotion.press,
              curve: YmMotion.pressCurve,
              // 底色**不做过渡**：母本 `.press{background:var(--press);transform:scale(.96);
              // transition:transform .25s}`（ui-kit.css:622）的 transition 只列了 transform，
              // 底色是瞬切的。原来用 AnimatedContainer 给底色加了 250ms 渐变，每次点击都比母本「软」。
              // border / boxShadow 挂在这里（缩放层内）而不是包在外层 Container：
              // 圆钮的描边和投影要跟底色一起下沉，只缩 child 会留下一个静止的圆环。
              child: Container(
                decoration: BoxDecoration(
                  color: background,
                  borderRadius:
                      widget.radius ?? BorderRadius.circular(YmRadius.ctrl),
                  border: widget.border,
                  boxShadow: widget.boxShadow,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.semanticLabel != null || widget.onTap != null) {
      result = Semantics(
        label: widget.semanticLabel,
        button: widget.onTap != null,
        enabled: widget.enabled,
        child: result,
      );
    }
    return result;
  }
}
