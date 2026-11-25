import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent, SwipeEdge;

import 'theme.dart';
import 'tokens.dart';

/// 推入页：层级横推（全工程默认语义——顶栏是返回箭头的页面都是它）。
///
/// [snapshot]：转场期间把整页拍成一张贴图来动（SDK Zoom 转场同方案）。
/// 真机实测（0.1.25）：不拍贴图时光栅线程每帧重画整页，重页面单帧 50~65ms、
/// 连掉 3~4 帧——必须开。**内嵌 WebView 的页面要传 false**（快照不支持
/// 平台视图：WebPage / LoginWebPage / ForumLoginPage）。
///
/// ⚠ 贴图由 [_YmTransitionSnapshot] **只在转场期间**开：路由动画一停就关掉，
/// 详见那个类的注释（0.1.26 修的「新页冻住」）。
///
/// 推入：新页 x 100%→0，旧页 x 0→−25% + 黑纱 12%；退出完全镜像。
/// 参数与曲线全部出自 [YmMotion]（`push` / `pushIn` / `pushStyle`，
/// 真机可切方案 A/B 与两套曲线，见 tokens 注释）。
PageRoute<T> ymRoute<T>(Widget page, {bool snapshot = true}) =>
    YmPageRoute<T>(page: page, snapshot: snapshot);

/// 模态浮层：淡入 + 缩放 [YmMotion.modalScale]→1（[YmMotion.screen] 口径），
/// 退出镜像。**全工程唯一例外是图片查看器**——顶栏是关闭钮 + 下滑关闭手势，
/// 「收起浮层」语义，不是「返回一层」语义（2026-11 第六期用户拍板）。
PageRoute<T> ymModalRoute<T>(Widget page) => YmModalRoute<T>(page: page);

/// 层级页基座：底色垫 [YmColors.bg] + 版心 780（资产包 SlateScaffold.pageMax）
/// 宽表面居中限宽、窄屏无感。
class _YmPageScaffold extends StatelessWidget {
  const _YmPageScaffold(this.page);

  final Widget page;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: YmScope.of(context).colors.bg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: YmLayout.pageMax),
          child: SizedBox.expand(child: page),
        ),
      ),
    );
  }
}

/// 层级路由：横推 + 预测式返回跟手预览。
///
/// 继承 `MaterialPageRoute` 走系统标准路线（§六.4 拍板倾向 (a)）：
/// 转场由 `PageTransitionsTheme` 里的 [YmPushTransitionsBuilder] 接管
/// （theme.dart 装配），预测式返回探测在 builder 内部做，业务层零感知。
class YmPageRoute<T> extends MaterialPageRoute<T> {
  YmPageRoute({required Widget page, this.snapshot = true})
      : super(builder: (BuildContext context) => _YmPageScaffold(page));

  final bool snapshot;

  @override
  Duration get transitionDuration => YmMotion.push;

  // 快照垫在页面与变换之间：光栅线程每帧只合成贴图，不重画页面内容。
  // SDK Zoom 转场同款方案（permissive + autoresize），但**只在转场期间开**
  // （[_YmTransitionSnapshot]）。
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      snapshot
          ? _YmTransitionSnapshot(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            )
          : child,
    );
  }

  /// 旧页是否跟着横推：模态盖顶时旧页不动（浮层语义，透明度/缩放过渡自己够）。
  /// 这是 TransitionRoute 的公开挂钩——false 时下方路由的 secondaryAnimation
  /// 保持 0，即本页推入/退出时上一页静止。
  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is YmPageRoute<dynamic>;
}

/// 模态路由（图片查看器专用）。
///
/// - 淡入 + 缩放 0.92→1，退出镜像（reverse 播放同一条曲线，口径同旧 ymRoute）；
/// - 不吃预测式返回 / 边缘手势（它的「返回」是下滑关闭与关闭钮，见类注释）；
///   系统返回键仍能关页（回落普通 pop，播同一条镜像动画）。
class YmModalRoute<T> extends MaterialPageRoute<T> {
  YmModalRoute({required Widget page, this.snapshot = true})
      : super(builder: (BuildContext context) => _YmPageScaffold(page));

  final bool snapshot;

  @override
  Duration get transitionDuration => YmMotion.screen;

  /// ⚠ 反向必须自己覆写（2026-11-16 实测）：`MaterialRouteTransitionMixin` 的
  /// `reverseTransitionDuration` 会去 theme 的 `PageTransitionsBuilder` 取，
  /// 而我们那个 builder 为了页面横推把正反都设成 420ms ⇒ 查看器关闭被"顺手"拖到 420，
  /// 打开 220 / 关闭 420，用户感受就是"关得比开慢一倍"。
  @override
  Duration get reverseTransitionDuration => YmMotion.screen;

  @override
  bool get popGestureEnabled => false;

  // 签名跟 MaterialRouteTransitionMixin.buildTransitions（3.47 无 route 参数），
  // route 即 this——模态不吃 theme 装配，进出场自己画。
  // 快照垫在页面与淡入缩放变换之间，口径同 YmPageRoute（光栅只挪贴图，
  // 且只在转场期间开）。
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final t =
        CurvedAnimation(parent: animation, curve: YmMotion.screenCurve);
    return AnimatedBuilder(
      animation: t,
      builder: (context, inner) => Opacity(
        opacity: t.value,
        child: Transform.scale(
          scale:
              YmMotion.modalScale + (1 - YmMotion.modalScale) * t.value,
          child: inner,
        ),
      ),
      child: snapshot
          ? _YmTransitionSnapshot(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            )
          : child,
    );
  }
}

/// 转场贴图闸门：**只在「这一页正在动」的时候**把页面拍成一张贴图。
///
/// 为什么非要有这个闸门（0.1.26 真机 bug）：`SnapshotWidget` 的贴图是一张
/// 静态照片，SDK 只在这几件事发生时才重拍——控制器广播、`allowSnapshotting`
/// 由 true 变 false、尺寸变化（`autoresize`）、dpr 变化、detach、dispose
/// （`_RenderSnapshotWidget` 的 `_childRaster` 全部置空点）。原先写成
/// `allowSnapshotting: true` 常开，于是转场结束后页面仍被那张照片盖着：
/// 数据回来、加载态换正文、列表重排**全都看不见**，只有尺寸恰好变了才闪一下，
/// 也就是用户看到的「新页被冻住」。更糟的是页面上还有一层 `RepaintBoundary`
/// （`_ModalScope` 的 `_page`），内容重绘根本冒不到这一层，连重拍都不会触发。
///
/// 判据用动画状态而不是 `isAnimating`：预测式返回拖到一半时控制器值是被直接
/// 写进去的（`handleUpdateBackGestureProgress`），此时 `isAnimating == false`
/// 但 status 是 forward/reverse——拖拽期间同样要贴图。
///
/// 关掉的时候 `allowSnapshotting` 变值 → 渲染对象自己丢掉旧贴图 → 恢复逐帧
/// 实时绘制，代价是转场收尾那一帧要把整页重画一次（重页面约 50ms，一帧）。
class _YmTransitionSnapshot extends StatefulWidget {
  const _YmTransitionSnapshot({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  /// 本页自己的进出场（推入 / 返回 / 预测手势跟手）。
  final Animation<double> animation;

  /// 被新页盖住时的退场（旧页也要贴图，否则它每个合成帧都要重画）。
  final Animation<double> secondaryAnimation;

  final Widget child;

  @override
  State<_YmTransitionSnapshot> createState() => _YmTransitionSnapshotState();
}

class _YmTransitionSnapshotState extends State<_YmTransitionSnapshot> {
  /// 控制器归 State 所有：`buildTransitions` 每次重建都会 new 一个新的
  /// `SnapshotController`，放在那儿的话「是否拍贴图」会随重建反复重来。
  final SnapshotController _controller = SnapshotController();

  static bool _moving(Animation<double> animation) {
    final AnimationStatus status = animation.status;
    return status == AnimationStatus.forward ||
        status == AnimationStatus.reverse;
  }

  void _sync() {
    final bool on = _moving(widget.animation) ||
        _moving(widget.secondaryAnimation);
    if (_controller.allowSnapshotting != on) {
      // 变值即通知：渲染对象收到后丢掉旧贴图并按新状态重绘。
      _controller.allowSnapshotting = on;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
    widget.secondaryAnimation.addStatusListener(_onStatus);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _YmTransitionSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
    if (oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      oldWidget.secondaryAnimation.removeStatusListener(_onStatus);
      widget.secondaryAnimation.addStatusListener(_onStatus);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    widget.secondaryAnimation.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus _) => _sync();

  @override
  Widget build(BuildContext context) => SnapshotWidget(
        controller: _controller,
        mode: SnapshotMode.permissive,
        autoresize: true,
        child: widget.child,
      );
}

/// 预测手势的共享状态：顶层页的探测器写、旧页侧动画读。
/// 静态单例是因为转场两侧是**两条路由**，框架没有公开的跨路由传话口。
class YmBackGestureState {
  const YmBackGestureState({
    this.active = false,
    this.isCommit = false,
    this.commitDrag = 0,
  });

  /// 预测手势进行中（含松手后的回弹 / 退出收尾）。
  final bool active;

  /// 松手提交（pop）收尾中：动画会被 SDK 重置回满屏值重放（见 watcher 注释），
  /// 两侧都要用 [commitDrag] 冻结起点，不能直接读动画值。
  final bool isCommit;

  /// commit 那一刻的拖距（0~1，越大拉得越远）。
  final double commitDrag;

  static const none = YmBackGestureState();
}

/// 全流程**唯一**进度：0 = 新页在右侧满幅（未开始），1 = 新页到位、旧页退满。
///
/// 新页位移 = `W×(1−p)`，旧页位移 = `pushOldShift×W×p`，两层共用同一个 p，
/// 所以瞬时速度比恒为 `1 : pushOldShift` —— 必然同时开始、同时结束
///（2026-11-16 用户按 Flyme 观感拍定；此前返回段两层用互为镜像的曲线，起手收尾对不上）。
double ymPushProgress({
  required double value,
  required AnimationStatus status,
  required YmBackGestureState state,
  double reverseFrom = 1.0,
}) {
  final double v = value.clamp(0.0, 1.0);
  if (state.active && state.isCommit) {
    // 松手提交：SDK 把控制器重置回 1 再反向放，所以从冻结点接着走到 0。
    final double pStart = (1 - state.commitDrag).clamp(0.0, 1.0);
    final double k = YmMotion.pushOutCurve.transform(1 - v);
    return pStart * (1 - k);
  }
  if (status == AnimationStatus.reverse) {
    // 返回。**这一支优先于 state.active**：预测手势取消后的回弹（controller 往 1 走）
    // 若被一次普通返回打断，手势状态可能还没清，此时必须按返回曲线走，
    // 否则会用线性映射 —— 表现就是「这次返回明显比平时慢」（2026-11-16 真机反馈）。
    //
    // 锚点 reverseFrom = 反向开始时的值：返回可能从中途起步（回弹只走了 60% 就被打断），
    // 直接套 1 − curve(1−v) 会让页面瞬间跳到 87% 处再慢慢爬，既跳又慢。
    final double from = reverseFrom.clamp(1e-6, 1.0);
    final double q = ((from - v) / from).clamp(0.0, 1.0);
    return from * (1 - YmMotion.pushOutCurve.transform(q));
  }
  if (state.active) {
    // 手势进行中 / 取消回弹：手指即进度（1:1，不再叠曲线）。
    return v;
  }
  // 推入：p 从 0 涨到 1。
  return YmMotion.pushInCurve.transform(v);
}

/// 层级横推 + 预测式返回组合 builder（挂进 `PageTransitionsTheme`，见 theme.dart）。
///
/// 平时播横推；侧拉返回进行中切成「跟手预览」形态——当前页**纯平移**跟着手指走
/// （不缩放、不加圆角，2026-11-16 用户拍板），上一页的露出靠它的
/// secondaryAnimation 自动反放（同一套逻辑两副面孔，低版本 / iOS 没有预测事件时
/// 自然只剩横推）。默认只认**左边**起手（[YmMotion.predictiveEdge]）。
class YmPushTransitionsBuilder extends PageTransitionsBuilder {
  const YmPushTransitionsBuilder();

  @override
  Duration get transitionDuration => YmMotion.push;

  @override
  Duration get reverseTransitionDuration => YmMotion.push;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return YmPredictiveBackWatcher(
      route: route,
      builder: (context, state, reverseFrom) => AnimatedBuilder(
        animation: animation,
        builder: (context, inner) {
          final double width = MediaQuery.sizeOf(context).width;

          // 纯横滑：整页平移，不缩放、不加圆角（2026-11-16 用户拍板）。
          // p 与旧页层共用（见 ymPushProgress），两层同时开始、同时结束。
          final double p = ymPushProgress(
            value: animation.value,
            status: animation.status,
            state: state,
            reverseFrom: reverseFrom,
          );
          return Transform.translate(
            offset: Offset((1 - p) * width, 0),
            child: inner,
          );
        },
        // 旧页侧：本页静止（secondary=0）时原样；被盖住时横推/黑纱在里层接手。
        child: _YmSecondaryTransition(
          secondaryAnimation: secondaryAnimation,
          child: child,
        ),
      ),
    );
  }
}

/// 旧页侧动画：推入时旧页退（A：−50% 位移 / B：微缩）+ 黑纱 + 垫底深色，
/// 转场期间吃掉点击（防误触）。
///
/// 时机（0.1.26 学 Flyme 真值重调）：旧页与新页**共用同一条深减速曲线**，
/// 推入瞬间旧页就开始位移（之前单独配 easeIn 的「出视野加速」起手速度为零，
/// 背景要等前一层过半才看得见在动，真机否掉）；返回时反放同一条曲线，
/// 旧页也是立刻回位。旧页永远先动，层级感才立得住。
///
/// 预测手势下旧页有自己的戏份（0.1.25 真机反馈）：盖住时它停在满幅退移上，
/// 顶页一缩小露出的边缘就是垫底深色——黑块。对策：手势一开始旧页在
/// [YmMotion] 的 0.3 拖距内**加速滑回满幅原位**垫在下面（系统预览的形态），
/// 黑块消失；松手取消回弹时再按原路退回去，全程无跳变。
class _YmSecondaryTransition extends StatefulWidget {
  const _YmSecondaryTransition({
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_YmSecondaryTransition> createState() => _YmSecondaryTransitionState();
}

class _YmSecondaryTransitionState extends State<_YmSecondaryTransition> {
  /// 反向（旧页回位）开始时的值，锚点语义同前层。
  double _reverseFrom = 1;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      _reverseFrom = widget.secondaryAnimation.value.clamp(0.0, 1.0);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.secondaryAnimation.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    widget.secondaryAnimation.removeStatusListener(_onStatus);
    super.dispose();
  }

  /// 退移系数 0~1：0 = 满幅原位，1 = 完全退移（−50% / 微缩到底）。
  ///
  /// 直接复用新页那条 [ymPushProgress]：两层同一个 p，速度比恒为 `1 : pushOldShift`。
  double _factor(double raw, YmBackGestureState state) => ymPushProgress(
        value: raw,
        status: widget.secondaryAnimation.status,
        state: state,
        reverseFrom: _reverseFrom,
      );

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    final Animation<double> secondary = widget.secondaryAnimation;
    return AnimatedBuilder(
      animation:
          Listenable.merge([secondary, YmPredictiveBackWatcher.gestureState]),
      builder: (context, inner) {
        final double raw = secondary.value;
        final state = YmPredictiveBackWatcher.gestureState.value;
        final double f = _factor(raw, state);

        Widget page = inner!;
        switch (YmMotion.pushStyle) {
          case YmPushStyle.parallax:
            page = Transform.translate(
              offset: Offset(-YmMotion.pushOldShift * width * f, 0),
              child: page,
            );
          case YmPushStyle.shrink:
            page = Transform.scale(
              scale: 1 - (1 - YmMotion.pushAltScale) * f,
              child: page,
            );
        }

        final double shade = YmMotion.pushStyle == YmPushStyle.parallax
            ? YmMotion.pushShade
            : YmMotion.pushAltShade;

        return ColoredBox(
          // 垫底深色：旧页位移/微缩露出背后时不许见黑/见白穿帮（tokens 注释）。
          color: YmMotion.pushUnderlay,
          child: IgnorePointer(
            // 转场期间（含退出反放）旧页吃掉点击，松手才可交互。
            ignoring: raw > 0 && raw < 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                page,
                if (raw > 0)
                  ColoredBox(
                    color: Color.fromRGBO(0, 0, 0, shade * f),
                  ),
              ],
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 预测式返回手势探测：镜像 SDK `_PredictiveBackGestureDetector` 的公开 API
/// 用法（`WidgetsBindingObserver.handleStartBackGesture` 系列 + 路由的
/// `handleStartBackGesture` 系列，都是 public）。
///
/// 为什么不用 SDK 的 `PredictiveBackPageTransitionsBuilder`：它的非手势回落
/// 写死成 FadeForwards，接不了自家的横推；这里自己探测手势，非手势回落
/// 直接给 [YmPushTransitionsBuilder] 的横推——一套逻辑两副面孔。
///
/// ⚠ commit 的坑（0.1.25 真机实证）：SDK 在松手提交时会 `navigator.pop()` +
/// `reverse(from: upperBound)` 把控制器**重置回 1** 再放退出动画——直接读
/// 动画值会先跳回满屏再抽一下。这里在调路由处理**之前**先抓下拖距存进
/// [YmBackGestureState.commitDrag]，转场两侧都从冻结位继续，视觉无跳变。
class YmPredictiveBackWatcher extends StatefulWidget {
  const YmPredictiveBackWatcher({
    super.key,
    required this.route,
    required this.builder,
  });

  final PageRoute<dynamic> route;
  final Widget Function(BuildContext, YmBackGestureState, double reverseFrom) builder;

  /// 共享给旧页侧动画的手势状态（见 [YmBackGestureState]）。
  static final ValueNotifier<YmBackGestureState> gestureState =
      ValueNotifier<YmBackGestureState>(YmBackGestureState.none);

  @override
  State<YmPredictiveBackWatcher> createState() => _YmPredictiveBackWatcherState();
}

class _YmPredictiveBackWatcherState extends State<YmPredictiveBackWatcher>
    with WidgetsBindingObserver {
  YmBackGestureState _state = YmBackGestureState.none;

  /// 反向（返回）开始时的动画值：返回可能从「取消回弹」的中途起步，
  /// `ymPushProgress` 用它做锚点，保证位移连续且仍然前加载。
  double _reverseFrom = 1;
  Animation<double>? _tracked;

  void _onAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.reverse) return;
    final Animation<double>? anim = _tracked;
    if (anim != null) _reverseFrom = anim.value.clamp(0.0, 1.0);
    // 回弹被普通返回打断时，手势状态不会再收到 completed，这里兜底清掉。
    if (_state.active && !_state.isCommit) {
      _publish(YmBackGestureState.none);
    }
  }

  bool get _enabled => widget.route.isCurrent && widget.route.popGestureEnabled;

  /// 这条边起手算不算预测手势（[YmMotion.predictiveEdge]，默认只认左边）。
  static bool _edgeAllowed(SwipeEdge edge) => switch (YmMotion.predictiveEdge) {
        YmPredictiveBackEdge.left => edge == SwipeEdge.left,
        YmPredictiveBackEdge.right => edge == SwipeEdge.right,
        YmPredictiveBackEdge.both => true,
      };

  void _publish(YmBackGestureState state) {
    _state = state;
    YmPredictiveBackWatcher.gestureState.value = state;
    if (mounted) setState(() {});
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final bool claimable = !backEvent.isButtonEvent &&
        _enabled &&
        _edgeAllowed(backEvent.swipeEdge);
    if (!claimable) {
      // 不认领的三种情况都交给框架/引擎回落（松手后普通 pop）：
      // 返回键、PopScope(doNotPop) 之类的页面、以及不认的那条边起手。
      return false;
    }
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    _publish(const YmBackGestureState(active: true));
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    widget.route
        .handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    // 回弹：控制器 forward 回满屏，保持手势形态跟着放完再撤（中途切形态会闪）。
    widget.route.handleCancelBackGesture();
    _settleGesture();
  }

  @override
  void handleCommitBackGesture() {
    // 先抓拖距再交给路由（路由会把控制器重置回 1，见类注释）。
    final double drag = 1 - (widget.route.animation?.value ?? 1);
    widget.route.handleCommitBackGesture();
    _publish(YmBackGestureState(active: true, isCommit: true, commitDrag: drag));
    _settleGesture();
  }

  /// 松手后等路由动画走完再撤手势形态（回弹或退出到下一页）。
  void _settleGesture() {
    if (!mounted) return;
    final Animation<double>? anim = widget.route.animation;
    if (anim == null) {
      _publish(YmBackGestureState.none);
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status.isCompleted || status.isDismissed) {
        anim.removeStatusListener(onStatus);
        _publish(YmBackGestureState.none);
      }
    }

    anim.addStatusListener(onStatus);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tracked = widget.route.animation;
    _tracked?.addStatusListener(_onAnimStatus);
  }

  @override
  void dispose() {
    _tracked?.removeStatusListener(_onAnimStatus);
    // 路由可能被 abrupt 移除（如 commit 后 pop 完成），保险起见清共享状态，
    // 不然下一页的转场会误以为还在手势里。
    if (_state.active) {
      YmPredictiveBackWatcher.gestureState.value = YmBackGestureState.none;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _state, _reverseFrom);
  }
}
