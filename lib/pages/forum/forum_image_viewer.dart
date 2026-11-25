import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../../data/cache/ym_cache_store.dart' show YmCache;
import '../../design/pressable.dart';
import '../../design/system_ui.dart' show setReaderImmersive;
import '../../design/tokens.dart';
import '../../design/widgets/forum/forum_image.dart';
import '../../design/widgets/glyph.dart' show YmCloseGlyph;
import '../../design/widgets/hscroll_fade.dart';
import '../../design/ym_route.dart';

/// 打开 H 图片查看器。[images] 是「同帖多图」序列（页面层按楼层顺序收平），
/// [initial] 是被点那张的下标。空序列不打开。
Future<void> openForumImageViewer(
  BuildContext context,
  List<String> images, {
  int initial = 0,
}) async {
  if (images.isEmpty) return;
  // 模态路由（全工程唯一例外）：淡入 + 缩放 0.92→1，「收起浮层」语义，
  // 不吃预测式返回；下滑关闭手势不受影响（2026-11 第六期拍板）。
  await Navigator.of(context).push(ymModalRoute(
    ForumImageViewer(images: images, initial: initial),
  ));
}

/// H 图片查看器（拆件表 H-01：复刻能力不复刻 UI；外观自绘，草稿 H 屏）。
///
/// 手势与漫画阅读器同源（锚点缩放公式 / 1x 轴判定 / 边界弹簧都照搬）：
/// - 双击：1x ↔ 2x，击点不动（`off1 = off0 − (tap − c − off0) · (s1 − s0)/s0`）；
/// - 双指捏合 1–4x；放大后单指平移，**松手带平台滚动物理惯性**（0.1.22 补：
///   照搬阅读器 `_startPanInertia` 的 FixedScrollMetrics 方案，撞到边界那轴清零）；
/// - 1x 单指：先按首段位移定轴 —— 横划左右换图（同帖多图连看），
///   竖划下滑关闭（拖过阈值或甩够快才关，否则弹回）；
/// - **单击切换沉浸**（0.1.22 补，与漫画阅读器同款）：工具栏滑出滑入 +
///   系统栏联动隐藏；双击缩放不受影响（两次 onTapUp 相互抵消）。
/// - 图片加载只走 [YmForumImage]（自带论坛侧 Referer，附件图缺了会被拒 —— 回归口径）。
///
/// 布局是「舞台全屏 + 顶栏/缩略条浮层」（漫画阅读器同构）：舞台内容 ClipRect
/// 裁剪——放大后的图**画不进顶栏/缩略条**（0.1.22 修：之前放大平移直接糊在按钮上）。
/// 深底舞台本身就是图片查看场景的一部分（草稿 `yf-viewer` 的 `--text` 深底），
/// 顶栏计数 small12·w700 白 72%，缩略条 44px（草稿 `yf-thumb`，圆角 8 / 未选中 45%）。
class ForumImageViewer extends StatefulWidget {
  const ForumImageViewer({super.key, required this.images, this.initial = 0});

  final List<String> images;
  final int initial;

  @override
  State<ForumImageViewer> createState() => _ForumImageViewerState();
}

class _ForumImageViewerState extends State<ForumImageViewer>
    with TickerProviderStateMixin {
  late int _index = widget.initial.clamp(0, widget.images.length - 1);

  /// 工具栏显隐（单击切换；收起时系统栏一起进沉浸）。
  bool _chrome = true;

  /* ------------------------------- 缩放舞台 ------------------------------ */

  double _scale = 1;
  Offset _offset = Offset.zero;
  bool get _zoomed => _scale > 1.01;

  // 各图原图宽高（订阅解码流拿的，漫画阅读器 `_natural` 同款）。
  // 限位基准是「图片在 scale=1 的显示矩形」——放大后图片边缘必须贴住屏幕边，
  // 不能按视口对称区间放（0.1.22 真机反馈：视口基准下图边会飘离屏幕边）。
  final Map<String, Size> _natural = <String, Size>{};

  // 手势进行中的起点（与阅读器 `_onScaleStart` 同名同义）
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  // 0 未定轴 / 1 横（换图）/ 2 竖（关闭）
  int _panAxis = 0;

  // 换图拖移（px，>0 拉出上一张、<0 拉出下一张）与下滑关闭位移
  double _drag = 0;
  double _vDy = 0;

  /* ------------------------- 放大后平移惯性（阅读器同款） ------------------ */

  // 单指惯性直接接 Flutter 的平台滚动物理：每轴把 offset 允许区间换算成
  // [0, span] 的 scroll 坐标记账，每帧映射回来；撞到边界的那条轴就地清零。
  Ticker? _panTicker;
  Simulation? _panX;
  Simulation? _panY;
  double _panFixedX = 0;
  double _panFixedY = 0;
  Offset _panLo = Offset.zero; // 各轴 offset 下界
  Offset _panSpan = Offset.zero; // 各轴可平移长度
  Size? _panSize;

  /* -------------------------------- 动画 -------------------------------- */

  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  @override
  void initState() {
    super.initState();
    setReaderImmersive(false); // 进查看器先保证系统栏在
  }

  @override
  void dispose() {
    setReaderImmersive(false); // 离开查看器恢复系统栏
    _stopPanInertia();
    _panTicker?.dispose();
    _anim.dispose();
    super.dispose();
  }

  /// 工具栏显隐与系统栏联动：收起时进入沉浸全屏（与漫画阅读器 `_setChrome` 同款）。
  void _setChrome(bool value) {
    if (_chrome == value) return;
    setState(() => _chrome = value);
    setReaderImmersive(!value);
  }

  /// 当前图在 scale=1 的显示矩形（相对视口）。contain + 居中，与阅读器
  /// `_baseRect` 同公式；原图尺寸没解出来前先按视口（offset 反正居中为 0）。
  ({double w, double h, double left, double top}) _baseRect(String url, Size size) {
    final n = _natural[url];
    if (n == null || n.width <= 0) {
      return (w: size.width, h: size.height, left: 0, top: 0);
    }
    final k = math.min(size.width / n.width, size.height / n.height);
    final w = n.width * k;
    final h = n.height * k;
    return (w: w, h: h, left: (size.width - w) / 2, top: (size.height - h) / 2);
  }

  /// 单轴 offset 允许区间（阅读器 `_offsetRange` 原样）：
  /// 缩放后内容比视口小就居中（上下界相同），否则**图片边缘贴住屏幕边缘**。
  (double, double) _offsetRange(
      double viewport, double base, double origin, double s) {
    final scaled = base * s;
    final c = viewport / 2;
    if (scaled <= viewport + 0.5) {
      final centered = (viewport - scaled) / 2 - origin * s - c * (1 - s);
      return (centered, centered);
    }
    final hi = -origin * s - c * (1 - s);
    final lo = viewport - scaled - origin * s - c * (1 - s);
    return (lo, hi);
  }

  Offset _clampOffset(Offset v, Size size, double s) {
    final base = _baseRect(_currentUrl, size);
    final rx = _offsetRange(size.width, base.w, base.left, s);
    final ry = _offsetRange(size.height, base.h, base.top, s);
    return Offset(v.dx.clamp(rx.$1, rx.$2), v.dy.clamp(ry.$1, ry.$2));
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF1C1C1E),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 舞台全屏 + 内容裁剪：放大后的图画不进顶栏/缩略条（0.1.22 修）
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, box) => ClipRect(
                  child: _stage(box.biggest, images),
                ),
              ),
            ),
            // 顶栏浮层（草稿 `yf-viewer-top`）
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: AnimatedSlide(
                  offset: _chrome ? Offset.zero : const Offset(0, -1),
                  duration: YmMotion.screen,
                  curve: YmMotion.screenCurve,
                  child: AnimatedOpacity(
                    opacity: _chrome ? 1 : 0,
                    duration: YmMotion.screen,
                    child: _TopBar(
                      index: _index,
                      total: images.length,
                      onClose: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),
            ),
            // 底部缩略条浮层（草稿 `yf-thumbs`）
            if (images.length > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !_chrome,
                  child: AnimatedSlide(
                    offset: _chrome ? Offset.zero : const Offset(0, 1),
                    duration: YmMotion.screen,
                    curve: YmMotion.screenCurve,
                    child: AnimatedOpacity(
                      opacity: _chrome ? 1 : 0,
                      duration: YmMotion.screen,
                      child: _Thumbs(
                        images: images,
                        index: _index,
                        onPick: (i, size) => _goTo(i, size),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /* ------------------------------- 舞台手势 ------------------------------ */

  Widget _stage(Size size, List<String> images) {
    final current = images[_index];
    // 换图中：邻图从侧边推进来（草稿没有此细节，与阅读器翻页同构）
    final neighborIndex = _drag == 0 ? -1 : _neighborIndex;
    final neighbor = neighborIndex >= 0 && neighborIndex < images.length
        ? images[neighborIndex]
        : '';
    // 邻图停靠边：拉上一张（drag>0）从左边进，拉下一张从右边进
    final neighborLeft = (_drag > 0 ? -size.width : size.width) + _drag;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _stopPanInertia(),
      onTapUp: (_) => _setChrome(!_chrome),
      onDoubleTapDown: (d) => _onDoubleTapDown(d, size),
      onDoubleTap: () {},
      onScaleStart: (d) => _onScaleStart(d, size),
      onScaleUpdate: (d) => _onScaleUpdate(d, size),
      onScaleEnd: (d) => _onScaleEnd(d, size),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (neighbor.isNotEmpty)
            Positioned(
              left: neighborLeft,
              top: 0,
              bottom: 0,
              width: size.width,
              child: YmForumImage(
                url: neighbor,
                fit: BoxFit.contain,
              ),
            ),
          Transform.translate(
            offset: Offset(_drag + _offset.dx, _offset.dy + _vDy),
            child: Transform.scale(
              scale: _scale,
              child: Opacity(
                opacity: _fade(size.height),
                child: _ViewerImage(
                  url: current,
                  onDecoded: (sz) {
                    if (_natural[current] == sz) return;
                    setState(() {
                      _natural[current] = sz;
                      // 原图尺寸到货，限位基准变了：就地钳一次
                      _offset = _clampOffset(_offset, size, _scale);
                    });
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  int get _neighborIndex => _drag > 0 ? _index - 1 : _index + 1;

  String get _currentUrl => widget.images[_index];

  /// 下滑关闭时正片淡出（草稿没有此细节：位移越大越透明，保底 0.35）。
  double _fade(double stageHeight) =>
      (1 - _vDy.abs() / (stageHeight * 0.9)).clamp(0.35, 1.0);

  void _resetZoom() {
    _scale = 1;
    _offset = Offset.zero;
    _vDy = 0;
    _drag = 0;
    _panAxis = 0;
  }

  void _onDoubleTapDown(TapDownDetails d, Size size) {
    _anim.stop();
    _stopPanInertia();
    final target = _zoomed ? 1.0 : 2.0;
    final c = size.center(Offset.zero);
    final s0 = _scale;
    final off0 = _clampOffset(_offset, size, s0);
    final off1 = off0 - (d.localPosition - c - off0) * ((target - s0) / s0);
    final fromScale = s0;
    final toScale = target;
    final fromOff = off0;
    final toOff = _clampOffset(off1, size, target);
    void tick(double t) {
      setState(() {
        _scale = _lerp(fromScale, toScale, t);
        _offset = Offset.lerp(fromOff, toOff, t)!;
      });
    }

    _drive(tick);
  }

  void _onScaleStart(ScaleStartDetails d, Size size) {
    _anim.stop();
    _stopPanInertia();
    _startScale = _scale;
    _startOffset = _clampOffset(_offset, size, _scale);
    _offset = _startOffset;
    _startFocal = d.localFocalPoint;
    _panAxis = 0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    // 换图 / 下滑途中变捏合：放弃这一轮，回正再缩
    if (d.pointerCount > 1 && (_drag != 0 || _vDy != 0)) {
      setState(() {
        _drag = 0;
        _vDy = 0;
        _panAxis = 0;
      });
      return;
    }
    if (d.pointerCount >= 2 || _zoomed) {
      // 放大态单指 = 平移；两指 = 捏合缩放（锚点公式照搬阅读器）
      final next = (_startScale * d.scale).clamp(1.0, 4.0);
      final ratio = next / _startScale;
      final focal = d.localFocalPoint;
      // viewport(p) = s·(p − c) + c + offset；中心 c 不能消掉（同阅读器注）
      final c = size.center(Offset.zero);
      final offset = focal - (_startFocal - c - _startOffset) * ratio - c;
      setState(() {
        _scale = next;
        _offset = _clampOffset(offset, size, next);
      });
      return;
    }
    // 1x 单指：先定轴
    if (_panAxis == 0) {
      final total = d.localFocalPoint - _startFocal;
      if (total.distance > 6) {
        _panAxis = total.dy.abs() > total.dx.abs() ? 2 : 1;
      }
    }
    if (_panAxis == 2) {
      // 下滑关闭：向下跟手，向上给阻力
      final dy = d.localFocalPoint.dy - _startFocal.dy;
      setState(() {
        _offset = Offset.zero;
        _vDy = dy > 0 ? dy : dy * 0.25;
      });
      return;
    }
    if (_panAxis == 1) {
      // 横向换图：首尾图贴边方向给阻力
      final raw = d.localFocalPoint.dx - _startFocal.dx;
      final blocked =
          (_drag > 0 && _index == 0) || (_drag < 0 && _index == widget.images.length - 1);
      setState(() => _drag = raw * (blocked ? 0.3 : 1).toDouble());
      return;
    }
  }

  void _onScaleEnd(ScaleEndDetails d, Size size) {
    // 放大态松手：低于 1.05 收回 1x，否则钳住位移；单指拖动松手接惯性
    if (_zoomed) {
      setState(() {
        if (_scale < 1.05) {
          _scale = 1;
          _offset = _clampOffset(_offset, size, 1);
        } else {
          _offset = _clampOffset(_offset, size, _scale);
        }
      });
      if (d.pointerCount <= 1) _startPanInertia(d, size);
      return;
    }
    if (_panAxis == 2) {
      _panAxis = 0;
      final v = d.velocity.pixelsPerSecond.dy;
      final passed = _vDy > size.height * 0.18 || v > 900;
      if (passed) {
        Navigator.of(context).pop();
        return;
      }
      // 没拖够：弹回原位
      final from = _vDy;
      void tick(double t) {
        setState(() {
          _vDy = from * (1 - t);
          _offset = Offset.zero;
        });
      }

      _drive(tick);
      return;
    }
    if (_panAxis == 1) {
      _panAxis = 0;
      final v = d.velocity.pixelsPerSecond.dx;
      final passed = _drag.abs() >= size.width * 0.3 || v.abs() > 600;
      if (!passed) {
        // 弹回原位
        final from = _drag;
        void tick(double t) {
          setState(() => _drag = from * (1 - t));
        }

        _drive(tick);
        return;
      }
      // 换图方向以拖移为准（位移太小则以甩向为准）：drag>0 = 拉出上一张（index−1）
      final dir = _drag.abs() > 4 ? (_drag > 0 ? -1 : 1) : (v > 0 ? -1 : 1);
      if (_index + dir < 0 || _index + dir >= widget.images.length) {
        final from = _drag;
        void tick(double t) {
          setState(() => _drag = from * (1 - t));
        }

        _drive(tick);
        return;
      }
      _turn(dir, size);
    }
  }

  /* --------------------------- 放大后平移惯性 ---------------------------- */

  void _startPanInertia(ScaleEndDetails d, Size size) {
    _stopPanInertia();
    final physics = ScrollConfiguration.of(context).getScrollPhysics(context);
    final v = d.velocity.pixelsPerSecond;
    if (v.distance < physics.minFlingVelocity) return;

    final base = _baseRect(_currentUrl, size);
    final rx = _offsetRange(size.width, base.w, base.left, _scale);
    final ry = _offsetRange(size.height, base.h, base.top, _scale);
    final off = _clampOffset(_offset, size, _scale);
    _panLo = Offset(rx.$1, ry.$1);
    _panSpan = Offset(rx.$2 - rx.$1, ry.$2 - ry.$1);
    // offset → scroll 坐标（0 = 该轴下界）
    _panFixedX = off.dx - _panLo.dx;
    _panFixedY = off.dy - _panLo.dy;

    ScrollMetrics metricsFor(
      double pixels,
      double max,
      double viewport,
      AxisDirection dir,
    ) =>
        FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: max,
          pixels: pixels,
          viewportDimension: viewport,
          axisDirection: dir,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );

    // 每条轴各要一条平台曲线；速度为 0 或该轴没有位移空间时不跑。
    _panX = (v.dx.abs() < 1 || _panSpan.dx <= 0.5)
        ? null
        : physics.createBallisticSimulation(
            metricsFor(_panFixedX, _panSpan.dx, size.width, AxisDirection.right),
            v.dx,
          );
    _panY = (v.dy.abs() < 1 || _panSpan.dy <= 0.5)
        ? null
        : physics.createBallisticSimulation(
            metricsFor(_panFixedY, _panSpan.dy, size.height, AxisDirection.down),
            v.dy,
          );
    if (_panX == null && _panY == null) return;
    _panSize = size;
    (_panTicker ??= createTicker(_onPanTick)).start();
  }

  void _onPanTick(Duration elapsed) {
    final size = _panSize;
    if (size == null) return;
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final raw = Offset(
      (_panX?.x(t) ?? _panFixedX) + _panLo.dx,
      (_panY?.x(t) ?? _panFixedY) + _panLo.dy,
    );
    // 滚动曲线不知道图片边界（原生里由 ScrollPosition 钳位），
    // 这里照做：撞到图边的那条轴就地清零，另一条轴继续滑完。
    final next = _clampOffset(raw, size, _scale);
    if ((next.dx - raw.dx).abs() > 0.25) {
      _panX = null;
      _panFixedX = next.dx - _panLo.dx;
    }
    if ((next.dy - raw.dy).abs() > 0.25) {
      _panY = null;
      _panFixedY = next.dy - _panLo.dy;
    }
    setState(() => _offset = next);
    final done = (_panX == null || _panX!.isDone(t)) &&
        (_panY == null || _panY!.isDone(t));
    if (done) _stopPanInertia();
  }

  void _stopPanInertia() {
    _panTicker?.stop();
    _panX = null;
    _panY = null;
  }

  /// 换图动画：当前图顺着拖移方向滑出、邻图从侧边滑入；收尾时切 [_index] 并复位。
  /// [toIndex] 给缩略条跳图用（可以跨多张，转场只走一步滑）。
  void _turn(int dir, Size size, {int? toIndex}) {
    _stopPanInertia();
    final from = _drag;
    // 当前图往拖移那侧继续走：换上一张（dir=−1）时滑向 +width
    final target = -dir * size.width;
    void tick(double t) {
      setState(() => _drag = _lerp(from, target, t));
    }

    _drive(tick, onDone: () {
      if (!mounted) return;
      setState(() {
        _index = (toIndex ?? _index + dir).clamp(0, widget.images.length - 1);
        _resetZoom();
      });
    });
  }

  /// 缩略条跳图：一步滑动到位（多张也只走一次转场，转场中邻图取相邻那张）。
  void _goTo(int i, Size size) {
    if (i == _index) return;
    final dir = i > _index ? 1 : -1;
    _turn(dir, size, toIndex: i);
  }

  /* -------------------------------- 动画驱动 ------------------------------ */

  void _drive(void Function(double t) tick, {VoidCallback? onDone}) {
    _anim.stop();
    void listener() {
      final t = Curves.easeOutCubic.transform(_anim.value);
      tick(t);
      if (_anim.isCompleted) {
        _anim.removeListener(listener);
        onDone?.call();
      }
    }

    _anim.addListener(listener);
    _anim.forward(from: 0);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// 顶栏：左关右计数（草稿 `yf-viewer-x`；34 圆按触控红线升到 42，拆件表 V-8）。
/// 背后衬一层向下渐隐的黑纱（0.1.22 补：白图上白计数会没影）。
class _TopBar extends StatelessWidget {
  const _TopBar({required this.index, required this.total, required this.onClose});

  final int index;
  final int total;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 16 + MediaQuery.paddingOf(context).top, 14, 10),
        child: Row(
          children: [
            // 关闭钮：白 14% 圆底 + 资产标准叉（YmCloseGlyph，SlateCloseButton
            // 同规格 26 盒/线宽 2；0.1.22 前是自造旋转条，非资产口径）
            YmPressable(
              kind: YmPressKind.neutral,
              baseColor: Colors.white.withValues(alpha: 0.14),
              pressedColor: Colors.white.withValues(alpha: 0.28),
              radius: BorderRadius.circular(21),
              onTap: onClose,
              child: SizedBox(
                width: 42,
                height: 42,
                child: Center(
                  child: YmCloseGlyph(size: 26, color: Colors.white),
                ),
              ),
            ),
            const Spacer(),
            Text(
              '${index + 1} / $total',
              style: TextStyle(
                fontSize: YmFont.small12,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部缩略条（草稿 `yf-thumbs`：44px、圆角 8、未选中 45%、选中白描边）。
/// 背后衬一层向上渐隐的黑纱（0.1.22 补：图上浮层要有衬底才看得清）。
class _Thumbs extends StatelessWidget {
  const _Thumbs({required this.images, required this.index, required this.onPick});

  final List<String> images;
  final int index;
  final void Function(int i, Size size) onPick;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: YmHScrollFade(
        // 渐隐端实色跟查看器深底走（默认取页面底 bg，在深底上是白的，会穿帮）
        color: const Color(0xFF1C1C1E),
        padding: EdgeInsets.fromLTRB(14, 18, 14, 10 + MediaQuery.paddingOf(context).bottom),
        focusIndex: index,
        // 首开就定位：从第 18 张图打开时胶卷必须直接滚到那张（0.1.22 真机反馈）
        focusOnMount: true,
        children: [
          for (var i = 0; i < images.length; i++)
            _Thumb(
              index: i,
              url: images[i],
              active: i == index,
              onTap: () => onPick(i, MediaQuery.sizeOf(context)),
            ),
        ],
      ),
    );
  }
}

/// 订阅图片解码流拿原始宽高（漫画阅读器 `_ReaderImage` 的论坛版）。
/// Provider 与 [YmForumImage] 同 url 同头 = 同一条缓存流，不吃双份流量；
/// 渲染本体仍是 YmForumImage（Referer/Cookie/失败占位全走它的口径）。
class _ViewerImage extends StatefulWidget {
  const _ViewerImage({required this.url, required this.onDecoded});

  final String url;
  final void Function(Size) onDecoded;

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<_ViewerImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveSize();
  }

  @override
  void didUpdateWidget(covariant _ViewerImage old) {
    super.didUpdateWidget(old);
    _resolveSize();
  }

  void _resolveSize() {
    // 与 [YmForumImage] 同一条图源：本机有就用量本地文件（离线保存过的帖子
    // 断网也能看大图并量到原图尺寸），没有才走网络。两处一起改，否则
    // 尺寸订阅与实际渲染会吃两份图（漫画阅读器踩过同一个坑）。
    final local = YmCache.instance.peekForumImageFile(widget.url);
    final provider = local != null
        ? FileImage(local) as ImageProvider<Object>
        : NetworkImage(widget.url, headers: forumImageHeaders());
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (identical(stream, _stream)) return;
    final oldStream = _stream;
    final oldListener = _listener;
    if (oldStream != null && oldListener != null) {
      oldStream.removeListener(oldListener);
    }
    _stream = stream;
    final listener = ImageStreamListener(
      (info, _) {
        final img = info.image;
        widget.onDecoded(Size(img.width.toDouble(), img.height.toDouble()));
      },
      // 加载失败只影响「量不到原图尺寸」（限位退视口基准），别把异常抛出去——
      // 失败日志由 YmForumImage 的 errorBuilder 记，这里吞掉不重复
      onError: (Object error, StackTrace? stackTrace) {},
    );
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    final s = _stream;
    final l = _listener;
    if (s != null && l != null) s.removeListener(l);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return YmForumImage(url: widget.url, fit: BoxFit.contain);
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.index,
    required this.url,
    required this.active,
    required this.onTap,
  });

  final int index;
  final String url;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final child = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: YmForumImage(url: url, width: 44, height: 44, fit: BoxFit.cover),
    );
    return YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      radius: BorderRadius.circular(8),
      semanticLabel: '第${index + 1}张缩略图',
      onTap: onTap,
      child: Opacity(
        opacity: active ? 1 : 0.45,
        child: active
            ? Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9.5),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: YmForumImage(url: url, width: 41, height: 41, fit: BoxFit.cover),
                ),
              )
            : child,
      ),
    );
  }
}
