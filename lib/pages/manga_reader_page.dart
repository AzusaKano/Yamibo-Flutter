import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart'
    show
        GestureDisposition,
        PointerCancelEvent,
        PointerDeviceKind,
        PointerDownEvent,
        PointerEvent,
        PointerMoveEvent,
        PointerUpEvent,
        ScaleGestureRecognizer,
        VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart' show Ticker;

import '../data/api.dart';
import '../data/bookmark.dart';
import '../data/cache/ym_cache_store.dart';
import '../data/http.dart';
import '../data/library.dart';
import '../data/manga_prefs.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../design/pressable.dart';
import '../design/system_ui.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import '../design/widgets/toast.dart';
import '../design/widgets/button.dart';
// 页码滑杆（第十六期提共用件）：从本文件私有 _PageSlider 原样搬出，视觉与交互不变。
import '../design/widgets/reader_page_slider.dart';

/// 漫画阅读器。
///
/// 两种形态（uni 版 manga-reader 的能力口径，Flutter 原生实现）：
/// - 单页（paged）：三格页轨 + 弹簧落位 + 捏合/双击缩放 + RTL 右开；
/// - 条漫（flow）：`ListView.builder` 连续滚动，惰性构建 + 图片流解码宽高，
///   不做 UNI 版那套手动窗口生长（列表虚拟化交给框架）。
class MangaReaderPage extends StatefulWidget {
  const MangaReaderPage({
    super.key,
    required this.detail,
    required this.chapter,
    this.initialPage = 1,
  });

  final YmMangaDetail detail;
  final YmChapterRef chapter;
  final int initialPage;

  @override
  State<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends State<MangaReaderPage>
    with TickerProviderStateMixin {
  late YmChapterRef _chapter;
  late int _page;

  final Map<int, String> _urls = <int, String>{};
  final Set<int> _inflightPages = <int>{};

  /// 站内书签清单（第 1 页就够，见 `data/bookmark.dart`）。`null` = 还没取到 / 取不到。
  YmBookmarkFeed? _marks;
  int _totalPages = 1;
  bool _loading = true;
  bool _needLogin = false;
  String? _error;
  int _reqGen = 0;
  int _imgNonce = 0;

  /* ----------------------------- 单页形态状态 ----------------------------- */

  double _drag = 0;
  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  bool _chrome = true;

  // 每页原图尺寸；续接 fitWidth 的基准矩形与缩放边界。
  final Map<int, Size> _natural = <int, Size>{};
  int _panAxis = 0; // 单指手势定轴：0 未定 / 1 横向翻页 / 2 纵向滚动

  // 翻页弹簧：`_turnPage != null` 表示松手/点击后正在滑向那一页。
  // 必须用 unbounded：弹簧输出的是像素坐标（0 → ±屏宽），
  // 普通 controller 会把值钳在 [0,1]，表现为"卡住后瞬间跳页"。
  late final AnimationController _turnCtrl = AnimationController.unbounded(vsync: this);
  static final SpringDescription _spring = SpringDescription(
    mass: 1,
    stiffness: 380,
    damping: 30,
  );
  int? _turnPage;

  // 双击缩放动画。
  late final AnimationController _zoomCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  double? _zoomFromScale;
  Offset? _zoomFromOffset;
  double _zoomToScale = 1;
  Offset _zoomToOffset = Offset.zero;

  // 单指惯性（放大平移 / 长图滚动共用）：直接接 Flutter 的平台滚动物理
  // （`ScrollConfiguration` 在 Android 给 ClampingScrollSimulation —— OverScroller
  // 的移植，总距离与系统一致；iOS 给 BouncingScrollSimulation）。
  // 每轴把 offset 换算成 [0, span] 的 scroll 坐标记账，每帧再映射回来；
  // 撞到图片边界的那条轴就地清零。
  Ticker? _panTicker;
  Simulation? _panX;
  Simulation? _panY;
  double _panFixedX = 0;
  double _panFixedY = 0;
  Offset _panLo = Offset.zero; // 各轴 offset 下界
  Offset _panSpan = Offset.zero; // 各轴可平移长度
  Size? _panSize;
  int _lastPointers = 0;

  /* ----------------------------- 条漫形态状态 ----------------------------- */

  final ScrollController _flowCtrl = ScrollController();
  final Map<int, double> _flowHeights = <int, double>{};
  int? _flowAlignPage;

  /// auto 判定：`form` 含「条漫」直接流式；形式未知时按第 1 页宽高比兜底。
  bool _autoFlow = false;
  bool _formKnown = false;

  int get totalPages => math.max(1, _totalPages);

  /// 末页之后还有一张章末过渡卡（虚拟页），只有单页形态用得到。
  int get _maxPage => totalPages + 1;

  bool get _zoomed => _scale > 1.01;

  bool get _flowMode => switch (YmMangaPrefs.instance.mode) {
        YmMangaMode.flow => true,
        YmMangaMode.paged => false,
        YmMangaMode.auto => _autoFlow,
      };

  bool get _rtl => YmMangaPrefs.instance.dir == YmMangaDir.rtl;

  YmChapterRef? get _nextChapterRef {
    final list = widget.detail.chapters;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == _chapter.id) {
        return i + 1 < list.length ? list[i + 1] : null;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _chapter = widget.chapter;
    _page = widget.initialPage;
    _autoFlow = widget.detail.form.contains('条漫');
    _formKnown = widget.detail.form.isNotEmpty;
    _turnCtrl.addListener(_onTurnTick);
    _turnCtrl.addStatusListener(_onTurnStatus);
    _zoomCtrl.addListener(_onZoomTick);
    if (widget.initialPage > 1) _flowAlignPage = widget.initialPage;
    setReaderImmersive(false); // 进阅读器先保证系统栏在
    _load(widget.initialPage);
    // 正文先发，书签状态后问：`user` 优先级的请求会抢正文的 lane 槽位
    _syncMarks();
  }

  @override
  void dispose() {
    _recordOnExit();
    setReaderImmersive(false); // 离开阅读器恢复系统栏
    _turnCtrl.dispose();
    _zoomCtrl.dispose();
    _stopPanInertia();
    _panTicker?.dispose();
    _flowCtrl.dispose();
    super.dispose();
  }

  /// 退出这一刻的页码就是「本次进度」：翻页回调只在页码落定时触发，
  /// 拖到一半退出、或条漫滚到一半退出都不会走到，所以补记一次。
  ///
  /// 两点讲究：
  /// - **延到本帧结束后再写**：`dispose` 期间 widget 树是锁住的，`recordRead` 里的
  ///   `notifyListeners` 会把详情页的监听者标脏，框架会抛
  ///   「setState() or markNeedsBuild() called when widget tree was locked」。
  /// - **立即落盘**（`immediate`）：退出后进程随时可能被杀，等不了 300ms 防抖。
  void _recordOnExit() {
    if (_totalPages <= 0) return; // 页数还没拿到就别把进度记成第 1 页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _record(immediate: true);
    });
  }

  /// 工具栏显隐与系统栏联动：收起时进入沉浸全屏。
  void _setChrome(bool value) {
    if (_chrome == value) return;
    setState(() => _chrome = value);
    setReaderImmersive(!value);
  }

  /* ------------------------------- 数据加载 ------------------------------ */

  Future<void> _load(int page, {bool force = false}) async {
    final gen = ++_reqGen;
    setState(() {
      _loadingFor(page);
    });
    try {
      final data = await fetchMangaChapter(_chapter.id, page: page, force: force);
      if (!mounted) return;
      _urls[data.page] = data.image;
      if (gen != _reqGen) return; // 过期响应：只进缓存，不回跳页码
      setState(() {
        _totalPages = math.max(_totalPages, data.totalPages);
        // 本地进度可能超过当前章节页数（章节有更新），钳回合法区间
        final nextPage = math.min(page, math.max(1, data.totalPages));
        final pageChanged = nextPage != _page;
        _page = nextPage;
        _loading = false;
        _needLogin = false;
        _error = null;
        _drag = 0;
        _imgNonce += 1; // 重建图片节点，避免拿到缓存里的失败图
        // 缩放属于「当前页」：只有页码真的变了才复位。页图晚到（预取没赶上、
        // 大图慢）时无条件复位会吃掉用户已经开始的双击/捏合缩放。
        if (pageChanged) {
          _resetZoom();
        }
      });
      _record();
      _prefetch();
      _maybePrefetchNextChapter();
    } catch (e) {
      if (!mounted || gen != _reqGen) return;
      setState(() {
        _loading = false;
        if (e is YmHttpError && e.isLoginRequired) {
          _needLogin = true;
        } else {
          _error = e is YmHttpError ? e.message : '加载失败';
        }
      });
    }
  }

  void _loadingFor(int page) {
    _loading = true;
    _needLogin = false;
  }

  /// 单页形态的预取窗口：[p+1, p-1, p+2, p+3]（uni 版同款），
  /// 全部走 chapter 通道的低优先级，翻页时的交互请求天然插队。
  void _prefetch() {
    for (final p in [_page + 1, _page - 1, _page + 2, _page + 3]) {
      _ensurePage(p);
    }
  }

  /// 到倒数第 2 页时预取下一话第 1 页，章末翻过去就能直接出图。
  void _maybePrefetchNextChapter() {
    if (_page < totalPages - 1) return;
    final next = _nextChapterRef;
    if (next == null) return;
    fetchMangaChapter(next.id, page: 1, prefetch: true).then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {},
    );
  }

  /// 任意页的数据兜底：页轨/条漫缺图时按需取，失败静默（交互请求会再来）。
  Future<void> _ensurePage(int p, {bool user = false, bool force = false}) async {
    if (p < 1 || p > totalPages) return;
    if (!force && _urls.containsKey(p)) return;
    if (!_inflightPages.add(p)) return;
    try {
      final data = await fetchMangaChapter(
        _chapter.id,
        page: p,
        prefetch: !user,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _urls[data.page] = data.image;
        _totalPages = math.max(_totalPages, data.totalPages);
        if (force) _imgNonce += 1;
      });
    } catch (_) {
      // 预取失败不弹错
    } finally {
      _inflightPages.remove(p);
    }
  }

  void _record({bool immediate = false}) {
    // 页数还没拿到（首屏加载中 / 加载失败）时不写，免得把进度记成 0 页
    if (_totalPages <= 0) return;
    final shown = math.min(_page, totalPages);
    YmLibrary.instance.recordRead(
      id: widget.detail.id,
      title: widget.detail.title,
      author: widget.detail.author,
      cat: widget.detail.cat,
      kind: 'manga',
      cover: widget.detail.cover,
      chapterTitle: _chapter.title,
      chapterId: _chapter.id,
      percent: shown / totalPages,
      page: shown,
      pages: totalPages,
      immediate: immediate,
    );
  }

  /* ------------------------------- 页面跳转 ------------------------------ */

  void _resetZoom() {
    _stopPanInertia();
    _zoomCtrl.stop();
    _scale = 1;
    _offset = Offset.zero;
  }

  /// 翻页/落位动画完成后（或被下一次手势打断时）统一收尾。
  void _onTurnTick() {
    if (!_turnCtrl.isAnimating) return;
    // unbounded 控制器的 value 就是弹簧的像素坐标，直接用
    setState(() => _drag = _turnCtrl.value);
  }

  void _onTurnStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final target = _turnPage;
    _turnPage = null;
    _drag = 0;
    if (target == null || target == _page) {
      setState(() {});
      return;
    }
    setState(() => _page = target);
    _afterPageSettled();
  }

  /// 立即结算进行中的翻页动画（连点排队：上一格直接落位，再开下一格）。
  void _flushTurn() {
    if (!_turnCtrl.isAnimating) return;
    final target = _turnPage;
    _turnCtrl.stop();
    _turnPage = null;
    _drag = 0;
    if (target != null && target != _page) {
      setState(() => _page = target);
      _afterPageSettled();
    } else {
      setState(() {});
    }
  }

  void _afterPageSettled() {
    _resetZoom(); // 新页回到 1x、长图回到顶部
    if (_page <= totalPages && !_urls.containsKey(_page)) {
      _load(_page);
      return;
    }
    _record();
    _prefetch();
    _maybePrefetchNextChapter();
  }

  /// 相邻翻页：带弹簧滑行（连点时会先结算上一格，表现为连续前进 N 页）。
  void _turn(int delta, {double velocity = 0}) {
    if (_flowMode) return;
    _flushTurn();
    final target = (_page + delta).clamp(1, _maxPage);
    if (target == _page) {
      _startSettle(velocity);
      return;
    }
    // ltr：下一页在右侧，向左拖（负方向）；rtl 镜像。
    final nextSign = _rtl ? 1 : -1;
    final w = _lastWidth;
    _startTurn(target, (delta > 0 ? nextSign : -nextSign) * w, velocity);
  }

  void _startTurn(int target, double to, double velocity) {
    _turnPage = target;
    _turnCtrl.animateWith(SpringSimulation(_spring, _drag, to, velocity));
  }

  void _startSettle(double velocity) {
    if (_drag.abs() < 0.5 && velocity.abs() < 50) {
      setState(() => _drag = 0);
      return;
    }
    _turnPage = null;
    _turnCtrl.animateWith(SpringSimulation(_spring, _drag, 0, velocity));
  }

  /// 跳页（滑杆/章末卡）：相邻页走滑行，远跳直接落位（不做跨页动画）。
  void _goPage(int page) {
    if (_flowMode) return;
    final target = page.clamp(1, _maxPage);
    final delta = target - _page;
    if (delta == 0) return;
    if (delta.abs() == 1) {
      _turn(delta);
    } else {
      _flushTurn();
      setState(() {
        _page = target;
        _drag = 0;
      });
      _afterPageSettled();
    }
  }

  void _goChapter(YmChapterRef ch, {int startPage = 1}) {
    _flushTurn();
    setState(() {
      _chapter = ch;
      _page = startPage;
      _urls.clear();
      _inflightPages.clear();
      _natural.clear();
      _totalPages = 1;
      _drag = 0;
      _resetFlowZoom();
      _flowHeights.clear();
      _needLogin = false;
      _error = null;
      _loading = true;
    });
    _resetZoom();
    _load(startPage);
    _syncMarks();
    if (_flowMode) {
      _flowAlignPage = startPage;
      if (_flowCtrl.hasClients) _flowCtrl.jumpTo(0);
    }
  }

  /* ------------------------------- 单页手势 ------------------------------ */

  double _lastWidth = 0;

  // 放大态「边界二滑翻页」：手势起手时已在边界的那一侧，第二滑朝外才算。
  int _edgeDir = 0; // +1 下一页 / -1 上一页 / 0 无
  bool _edgeDecided = false;
  bool _turnDrag = false;

  /// 图片在 scale=1 时的实际显示矩形（相对视口）。缩放和平移的边界都以它为准，
  /// 所以 contain 模式下放大后不会把 letterbox 黑边拉进视口。
  ({double w, double h, double left, double top}) _baseRect(
      int page, Size size) {
    final n = _natural[page];
    if (n == null || n.width <= 0) {
      return (w: size.width, h: size.height, left: 0, top: 0); // 尺寸未知先按视口
    }
    if (YmMangaPrefs.instance.fitWidth) {
      final h = size.width * n.height / n.width;
      return (
        w: size.width,
        h: h,
        left: 0,
        top: h >= size.height ? 0 : (size.height - h) / 2,
      );
    }
    final k = math.min(size.width / n.width, size.height / n.height);
    final w = n.width * k;
    final h = n.height * k;
    return (
      w: w,
      h: h,
      left: (size.width - w) / 2,
      top: (size.height - h) / 2,
    );
  }

  /// 单轴的 offset 允许区间：内容比视口小就居中（上下界相同），否则边界贴图边。
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

  Offset _clampToBase(Offset v, Size size, double s, {int? page}) {
    final base = _baseRect(page ?? _page, size);
    final rx = _offsetRange(size.width, base.w, base.left, s);
    final ry = _offsetRange(size.height, base.h, base.top, s);
    return Offset(v.dx.clamp(rx.$1, rx.$2), v.dy.clamp(ry.$1, ry.$2));
  }

  /// 当前页在 1x 下能否纵向滚动（长图）。
  bool _canScrollV(Size size) {
    final base = _baseRect(_page, size);
    final r = _offsetRange(size.height, base.h, base.top, 1);
    return r.$2 - r.$1 > 0.5;
  }

  /// 起手时图片是否已顶在横向边界上；返回这一手朝外能翻的页。
  int _edgeTurnDir(Size size) {
    if (!_zoomed) return 0;
    final base = _baseRect(_page, size);
    final rx = _offsetRange(size.width, base.w, base.left, _scale);
    if (rx.$2 - rx.$1 <= 0.5) return 0;
    const eps = 0.5;
    if (_offset.dx <= rx.$1 + eps) {
      // 看到图片右边缘：LTR 继续往左 = 下一页；RTL 往左 = 上一页
      if (_rtl) return _page > 1 ? -1 : 0;
      return _page < _maxPage ? 1 : 0;
    }
    if (_offset.dx >= rx.$2 - eps) {
      if (_rtl) return _page < _maxPage ? 1 : 0;
      return _page > 1 ? -1 : 0;
    }
    return 0;
  }

  /// 翻页方向对应的「朝外」位移符号（屏幕 x 轴）。
  double _edgeOutSign() {
    if (_edgeDir > 0) return _rtl ? 1 : -1;
    return _rtl ? -1 : 1;
  }

  void _onScaleStart(ScaleStartDetails d, Size size) {
    _zoomCtrl.stop();
    _stopPanInertia(); // 按住即接管：从当前落点继续拖
    _flushTurn();
    _lastPointers = d.pointerCount;
    _startScale = _scale;
    _startOffset = _clampToBase(_offset, size, _scale);
    _offset = _startOffset;
    _startFocal = d.localFocalPoint;
    // 放大态：这一手起点是否已经顶在横向边界上（决定第二滑能不能翻页）。
    // 必须「先顶到边、松开、再滑」——同一次滑动里顶到边不算，避免误翻。
    _edgeDir = _edgeTurnDir(size);
    _edgeDecided = false;
    _turnDrag = false;
    _panAxis = 0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    _lastPointers = d.pointerCount;
    if (_turnDrag) {
      if (d.pointerCount > 1) {
        // 半路变捏合：放弃这一轮翻页，弹回原位
        _turnDrag = false;
        _edgeDir = 0;
        setState(() => _drag = 0);
        return;
      }
      final out = _edgeOutSign();
      final shift = _drag + d.focalPointDelta.dx;
      setState(() {
        _drag = out < 0 ? shift.clamp(-size.width, 0.0) : shift.clamp(0.0, size.width);
      });
      return;
    }
    if (d.pointerCount >= 2 || _zoomed) {
      if (_zoomed &&
          _edgeDir != 0 &&
          !_edgeDecided &&
          d.pointerCount == 1 &&
          (d.scale - 1).abs() < 0.02) {
        final total = d.localFocalPoint - _startFocal;
        if (total.distance > 6) {
          _edgeDecided = true;
          final out = _edgeOutSign();
          if (total.dx * out > 0 && total.dx.abs() > total.dy.abs()) {
            // 起手就是朝外横划：整页跟着手指走，邻页从侧边推进来
            _turnDrag = true;
            setState(() {
              _drag = out < 0
                  ? total.dx.clamp(-size.width, 0.0)
                  : total.dx.clamp(0.0, size.width);
            });
            return;
          }
          _edgeDir = 0; // 这一手不是朝外划，本手不翻页
        }
      }
      final next = (_startScale * d.scale).clamp(1.0, 4.0);
      final ratio = next / _startScale;
      final focal = d.localFocalPoint;
      // 锚点公式：手指下的内容点保持不动。
      // viewport(p) = s·(p − c) + c + offset，对 offset 求解时中心 c 不能消掉，
      // 少了 −c(1 − ratio) 项会让缩放锚点漂移半个屏幕（双击缩放走的是另一条
      // 已正确的公式，单指平移 ratio=1 时该项为零，所以只有捏合缩放会歪）。
      final c = size.center(Offset.zero);
      final offset = focal - (_startFocal - c - _startOffset) * ratio - c;
      setState(() {
        _scale = next;
        _offset = _clampToBase(offset, size, next);
      });
      return;
    }
    // 单指：先按首段位移定轴，避免斜着拖时既翻页又滚动。
    if (_panAxis == 0) {
      final total = d.localFocalPoint - _startFocal;
      if (total.distance > 6) {
        _panAxis = _canScrollV(size) && total.dy.abs() > total.dx.abs() ? 2 : 1;
      }
    }
    if (_panAxis == 2) {
      setState(() {
        // offset 向上为负：手指上滑（dy<0）让内容上移
        _offset = _clampToBase(
          Offset(_offset.dx, _offset.dy + d.focalPointDelta.dy),
          size,
          1,
        );
      });
      return;
    }
    setState(() {
      _drag = (_drag + d.focalPointDelta.dx).clamp(-size.width, size.width);
    });
  }

  void _onScaleEnd(ScaleEndDetails d, Size size) {
    final pointers = _lastPointers;
    _lastPointers = 0;
    if (_zoomed) {
      if (_turnDrag) {
        // 第二滑的收尾：够 18% 屏宽或朝外甩得够快就翻页，否则弹回原位。
        final dir = _edgeDir;
        final v = d.velocity.pixelsPerSecond.dx;
        final out = _edgeOutSign();
        final passed =
            _drag * out >= size.width * 0.18 || v * out > 600;
        _turnDrag = false;
        _edgeDir = 0;
        _edgeDecided = false;
        if (passed && dir != 0) {
          _turn(dir,
              velocity: _rtl
                  ? (dir > 0 ? v : -v.abs())
                  : (dir > 0 ? -v.abs() : v));
        } else {
          _startSettle(v);
        }
        return;
      }
      _edgeDir = 0;
      _edgeDecided = false;
      setState(() {
        if (_scale < 1.05) {
          // 捏合缩回 1x：保留当前看到的位置（长图别弹回顶部），只把倍率收掉。
          _scale = 1;
          _offset = _clampToBase(_offset, size, 1);
        } else {
          _offset = _clampToBase(_offset, size, _scale);
        }
      });
      // 单指拖动松手才有惯性；捏合结束（两指）不抛。
      if (_zoomed && pointers <= 1) _startPanInertia(d, size);
      return;
    }
    _edgeDir = 0;
    _edgeDecided = false;
    if (_panAxis == 2) {
      _panAxis = 0;
      _startPanInertia(d, size); // 长图滚动：同一套平台滚动惯性
      return;
    }
    _panAxis = 0;
    final v = d.velocity.pixelsPerSecond.dx;
    final threshold = size.width * 0.18;
    // ltr：向左拖 / 向左甩 = 下一页；rtl 镜像。弹簧承接松手速度（带符号）。
    final next = _rtl ? (v > 600) : (v < -600);
    final prev = _rtl ? (v < -600) : (v > 600);
    if (next || (!_rtl && _drag < -threshold) || (_rtl && _drag > threshold)) {
      _turn(1, velocity: _rtl ? v : -v.abs());
    } else if (prev || (!_rtl && _drag > threshold) || (_rtl && _drag < -threshold)) {
      _turn(-1, velocity: _rtl ? -v.abs() : v);
    } else {
      _startSettle(v);
    }
  }

  /* ------------------------------ 放大后惯性 ----------------------------- */

  void _startPanInertia(ScaleEndDetails d, Size size) {
    _stopPanInertia();
    final physics = ScrollConfiguration.of(context).getScrollPhysics(context);
    final v = d.velocity.pixelsPerSecond;
    if (v.distance < physics.minFlingVelocity) return;

    final base = _baseRect(_page, size);
    final rx = _offsetRange(size.width, base.w, base.left, _scale);
    final ry = _offsetRange(size.height, base.h, base.top, _scale);
    final off = _clampToBase(_offset, size, _scale);
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
    if (_panFlowX) {
      final rawLocal = _flowXSim!.x(t);
      final raw = rawLocal * _flowXScale - _flowXHalf;
      final next = raw.clamp(-_flowXHalf, _flowXHalf);
      setState(() => _flowOffset = Offset(next, _flowOffset.dy));
      if ((next - raw).abs() > 0.25 || _flowXSim!.isDone(t)) {
        _stopFlowXFling();
      }
      return;
    }
    final raw = Offset(
      (_panX?.x(t) ?? _panFixedX) + _panLo.dx,
      (_panY?.x(t) ?? _panFixedY) + _panLo.dy,
    );
    // 滚动曲线不知道图片边界（原生里由 ScrollPosition 钳位），
    // 这里照做：撞到图边的那条轴就地清零，另一条轴继续滑完。
    final next = _clampToBase(raw, size, _scale);
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
    _panFlowX = false;
    _flowXSim = null;
    _panTicker?.stop();
    _panX = null;
    _panY = null;
    _panSize = null;
  }

  void _onTapUp(TapUpDetails d, Size size) {
    if (_zoomed) {
      _setChrome(!_chrome);
      return;
    }
    final x = d.localPosition.dx;
    // ltr：左 30% 上一页、右 30% 下一页；rtl 对调。
    final leftIsPrev = !_rtl;
    if (x < size.width * 0.3) {
      _turn(leftIsPrev ? -1 : 1);
    } else if (x > size.width * 0.7) {
      _turn(leftIsPrev ? 1 : -1);
    } else {
      _setChrome(!_chrome);
    }
  }

  /* ------------------------------- 双击缩放 ------------------------------ */

  void _onZoomTick() {
    final t = Curves.easeOutCubic.transform(_zoomCtrl.value);
    setState(() {
      if (_flowMode) {
        _flowScale = lerpDouble(_zoomFromScale!, _zoomToScale, t)!;
        _flowOffset = Offset.lerp(_zoomFromOffset!, _zoomToOffset, t)!;
      } else {
        _scale = lerpDouble(_zoomFromScale!, _zoomToScale, t)!;
        _offset = Offset.lerp(_zoomFromOffset!, _zoomToOffset, t)!;
      }
    });
  }

  void _onDoubleTapDown(TapDownDetails d, Size size) {
    if (_flowMode) return;
    // 与捏合（_onScaleStart）对齐：先把进行中的翻页弹簧结算掉再缩放。
    // 弹簧的视觉落位（约 0.4s）早于控制器收尾（约 1.0s），这段窗口里双击，
    // 收尾的 _afterPageSettled -> _resetZoom 会把这一轮缩放打回 1。
    _flushTurn();
    _stopPanInertia(); // 惯性滑行中双击：先停住再从落点缩放
    final target = _zoomed ? 1.0 : 2.0;
    final c = size.center(Offset.zero);
    final s0 = _scale;
    final off0 = _clampToBase(_offset, size, s0);
    // 保持击点不动：off1 = off0 − (s1 − s0)/s0 · (tap − c − off0)。
    // 长图可能已经滚了一段，这里必须带上 off0，不能从 0 起算。
    final off1 = off0 - (d.localPosition - c - off0) * ((target - s0) / s0);
    _zoomFromScale = s0;
    _zoomFromOffset = off0;
    _zoomToScale = target;
    _zoomToOffset = _clampToBase(off1, size, target);
    _zoomCtrl.forward(from: 0);
  }

  /* ------------------------------- 条漫形态 ------------------------------ */

  double _flowEstimateH = 0;

  // 条漫的视口缩放：缩放的是整个滚动画布（列表照常滚动），
  // 纵向移动仍由列表负责，横向/锚点靠这条 offset。
  double _flowScale = 1;
  Offset _flowOffset = Offset.zero;
  double _flowStartScale = 1;
  Offset _flowStartOffset = Offset.zero;
  Offset _flowStartFocal = Offset.zero;

  // 放大后的横向跟手：原始 Listener 不受竞技场影响，所以能和列表的纵向滚动
  // 同时发生；松手用同一套平台 physics 走惯性（换算成局部单位，和列表同曲线）。
  final Set<int> _flowPointers = <int>{};
  final Map<int, Offset> _flowPointerPos = <int, Offset>{};
  VelocityTracker? _flowVX;
  PointerDeviceKind? _flowKind;
  Simulation? _flowXSim;
  double _flowXScale = 1;
  double _flowXHalf = 0;
  bool _panFlowX = false;

  Offset _clampFlow(Offset v, Size size, double s) {
    final rx = _offsetRange(size.width, size.width, 0, s);
    final ry = _offsetRange(size.height, size.height, 0, s);
    return Offset(v.dx.clamp(rx.$1, rx.$2), v.dy.clamp(ry.$1, ry.$2));
  }

  void _resetFlowZoom() {
    _zoomCtrl.stop();
    _stopFlowXFling();
    _flowPointers.clear();
    _flowPointerPos.clear();
    _flowVX = null;
    _flowScale = 1;
    _flowOffset = Offset.zero;
  }

  void _onFlowDoubleTapDown(TapDownDetails d, Size size) {
    _zoomCtrl.stop();
    _stopFlowXFling();
    final target = _flowScale > 1.01 ? 1.0 : 2.0;
    final c = size.center(Offset.zero);
    final s0 = _flowScale;
    final off0 = _flowOffset;
    final off1 = off0 - (d.localPosition - c - off0) * ((target - s0) / s0);
    _zoomFromScale = s0;
    _zoomFromOffset = off0;
    _zoomToScale = target;
    _zoomToOffset = _clampFlow(off1, size, target);
    _zoomCtrl.forward(from: 0);
  }

  void _onFlowScaleStart(ScaleStartDetails d) {
    _zoomCtrl.stop();
    _stopFlowXFling();
    _flowStartScale = _flowScale;
    _flowStartOffset = _flowOffset;
    _flowStartFocal = d.localFocalPoint;
  }

  void _onFlowScaleUpdate(ScaleUpdateDetails d, Size size) {
    if (d.pointerCount < 2) {
      // 单指横向由外层原始 Listener 并行处理，这里只做捏合
      return;
    }
    final next = (_flowStartScale * d.scale).clamp(1.0, 4.0);
    final ratio = next / _flowStartScale;
    final c = size.center(Offset.zero);
    final offset =
        d.localFocalPoint - (_flowStartFocal - c - _flowStartOffset) * ratio - c;
    setState(() {
      _flowScale = next;
      _flowOffset = _clampFlow(offset, size, next);
    });
  }

  void _onFlowScaleEnd(ScaleEndDetails d, Size size) {
    if (_flowScale < 1.02) {
      setState(() {
        _flowScale = 1;
        _flowOffset = Offset.zero;
      });
    } else {
      setState(() {
        _flowOffset = _clampFlow(_flowOffset, size, _flowScale);
      });
    }
  }

  /* --------------------------- 条漫横向跟手/惯性 -------------------------- */

  void _onFlowPointerDown(PointerDownEvent e) {
    _stopFlowXFling();
    _flowPointers.add(e.pointer);
    _flowPointerPos[e.pointer] = e.position;
    _flowKind = e.kind;
    _flowVX = _flowPointers.length == 1 && _flowScale > 1.01
        ? (VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.position))
        : null;
  }

  void _onFlowPointerMove(PointerMoveEvent e, Size size) {
    _flowPointerPos[e.pointer] = e.position;
    if (_flowPointers.length != 1 ||
        _flowVX == null ||
        _flowScale <= 1.01) {
      return;
    }
    _flowVX!.addPosition(e.timeStamp, e.position);
    final half = (size.width * _flowScale - size.width) / 2;
    if (half <= 0.5) return;
    setState(() {
      _flowOffset = Offset(
        (_flowOffset.dx + e.delta.dx).clamp(-half, half),
        _flowOffset.dy,
      );
    });
  }

  void _onFlowPointerUp(PointerUpEvent e, Size size) {
    final wasSingle = _flowPointers.length == 1;
    final tracker = _flowVX;
    _flowPointers.remove(e.pointer);
    _flowPointerPos.remove(e.pointer);
    if (_flowPointers.isEmpty) {
      _flowVX = null;
      if (wasSingle && tracker != null) {
        _startFlowXFling(tracker.getVelocity().pixelsPerSecond.dx, size);
      }
      return;
    }
    if (_flowPointers.length == 1) {
      // 捏合后剩一根：以剩下的手指重新起算横向速度
      final id = _flowPointers.first;
      final pos = _flowPointerPos[id];
      _flowVX = pos == null || _flowScale <= 1.01
          ? null
          : (VelocityTracker.withKind(_flowKind ?? e.kind)
            ..addPosition(e.timeStamp, pos));
    } else {
      _flowVX = null;
    }
  }

  void _onFlowPointerCancel(PointerCancelEvent e) {
    _flowPointers.remove(e.pointer);
    _flowPointerPos.remove(e.pointer);
    if (_flowPointers.isEmpty) _flowVX = null;
    _stopFlowXFling();
  }

  /// 横向松手惯性：和列表同一套平台曲线。列表在缩放层里收到的是局部速度
  /// （v/s），这里也换算成局部单位再模拟、回乘 s，两轴在屏幕上走同一条衰减曲线。
  void _startFlowXFling(double vScreen, Size size) {
    _stopFlowXFling();
    if (_flowScale <= 1.01) return;
    final half = (size.width * _flowScale - size.width) / 2;
    if (half <= 0.5) return;
    final physics = ScrollConfiguration.of(context).getScrollPhysics(context);
    final s = _flowScale;
    // 列表在缩放层里按局部速度判定起抛；这里同样用局部速度，阈值才一致
    if ((vScreen / s).abs() < physics.minFlingVelocity) return;
    final spanLocal = 2 * half / s;
    final posLocal = ((_flowOffset.dx + half) / s).clamp(0.0, spanLocal);
    final sim = physics.createBallisticSimulation(
      FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: spanLocal,
        pixels: posLocal,
        viewportDimension: size.width / s,
        axisDirection: AxisDirection.right,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      ),
      vScreen / s,
    );
    if (sim == null) return;
    _flowXSim = sim;
    _flowXScale = s;
    _flowXHalf = half;
    _panSize = size;
    _panFlowX = true;
    (_panTicker ??= createTicker(_onPanTick)).start();
  }

  void _stopFlowXFling() {
    if (!_panFlowX) return;
    _panFlowX = false;
    _flowXSim = null;
    _panTicker?.stop();
  }

  double _flowHeightOf(int page, double width) {
    final known = _flowHeights[page];
    if (known != null) return known;
    return _flowEstimateH <= 0 ? width * 1.9 : _flowEstimateH;
  }

  double _flowOffsetOf(int page, double width) {
    var acc = 0.0;
    for (var i = 1; i < page; i++) {
      acc += _flowHeightOf(i, width);
    }
    return acc;
  }

  /// 滚动时按「视口 1/3 线」所在页同步当前页码（uni 版同口径）。
  void _syncFlowPage(double width, double viewportH) {
    if (!_flowCtrl.hasClients) return;
    final line = _flowCtrl.offset + viewportH / 3;
    var acc = 0.0;
    var current = 1;
    for (var p = 1; p <= totalPages; p++) {
      if (acc > line) break;
      current = p;
      acc += _flowHeightOf(p, width);
    }
    if (current != _page) {
      setState(() => _page = current);
      _record();
      _prefetch();
      _maybePrefetchNextChapter();
    }
  }

  void _alignFlow(double width) {
    final target = _flowAlignPage;
    if (target == null) return;
    _flowAlignPage = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_flowCtrl.hasClients) return;
      _flowCtrl.jumpTo(_flowOffsetOf(target, width));
    });
  }

  /* -------------------------------- 书签 -------------------------------- */

  /// 当前这一页是否已钉着书签。**页码一起对上**才算 ——
  /// 同章不同页时算「没钉」，于是点一下就是把书签更新到当前页。
  bool get _pinned => bookmarkedAt(_marks, chaptId: _chapter.id, page: _page);

  Future<void> _syncMarks() async {
    final feed = await probeBookmarks();
    if (!mounted) return;
    setState(() => _marks = feed);
  }

  void _toast(String text) {
    showYmToast(context, text, bottomOffset: 84);
  }

  /// 加 / 取消书签。站点是**翻转**接口，一本书只有一条书签 ⇒
  /// 「加」在别的章 / 别的页已有书签时是**覆盖**（书签移到当前位置）。
  Future<void> _bookmark() async {
    if (!YmSession.loggedIn) {
      _toast('登录后可使用书签');
      return;
    }
    final wasPinned = _pinned;
    final chaptId = _chapter.id;
    final page = math.max(1, _page);
    try {
      final r = await setBookmarkAt(
        workId: widget.detail.id,
        chaptId: chaptId,
        manga: true,
        pinned: wasPinned,
        page: page,
        csrfToken: widget.detail.csrfToken,
      );
      if (!mounted) return;
      if (!r.ok) {
        _toast('没能保存书签，请稍后再试');
        return;
      }
      _toast(r.on ? '已加书签' : '已取消书签');
      _syncMarks();
    } on YmHttpError catch (e) {
      if (!mounted) return;
      _toast(e.isLoginRequired ? '登录后可使用书签' : '没能保存书签，请稍后再试');
    } catch (_) {
      if (!mounted) return;
      _toast('没能保存书签，请稍后再试');
    }
  }

  /* -------------------------------- 目录 -------------------------------- */

  void _openToc() {
    showYmSheet<void>(
      context,
      builder: (ctx) => YmTocSheet(
        title: '目录',
        unit: '话',
        chapters: widget.detail.chapters,
        currentId: _chapter.id,
        onPick: (ch) {
          Navigator.of(ctx).pop();
          _goChapter(ch);
        },
      ),
    );
  }

  /* ------------------------------- 设置面板 ------------------------------ */

  void _openSettings() {
    showYmSheet<void>(
      context,
      builder: (ctx) => AnimatedBuilder(
        animation: YmMangaPrefs.instance,
        builder: (ctx, _) {
          final c = YmScope.of(ctx).colors;
          final p = YmMangaPrefs.instance;
          final flow = _flowMode;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const YmSheetHeader(title: '阅读设置'),
                const SizedBox(height: 12),
                // 面板内分组标题（下面三处同档）：13·800 是资产包已声明的组合
                // ——分类面板标题「13 / 800 / --text-2」（composites/category_bar.dart），故保留。
                Text(
                  '显示模式',
                  style: TextStyle(
                    fontSize: YmFont.sub13,
                    fontWeight: FontWeight.w800,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _modeChip(ctx, '自动', YmMangaMode.auto),
                    const SizedBox(width: 8),
                    _modeChip(ctx, '条漫连续', YmMangaMode.flow),
                    const SizedBox(width: 8),
                    _modeChip(ctx, '单页翻页', YmMangaMode.paged),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '翻页方向',
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
                      label: '左→右',
                      compact: true,
                      active: p.dir == YmMangaDir.ltr,
                      onTap: () {
                        p.dir = YmMangaDir.ltr;
                        p.changed();
                      },
                    ),
                    const SizedBox(width: 8),
                    YmChip(
                      style: YmChipStyle.pill,
                      pressKind: YmPressKind.solid,
                      label: '左←右',
                      compact: true,
                      active: p.dir == YmMangaDir.rtl,
                      onTap: () {
                        p.dir = YmMangaDir.rtl;
                        p.changed();
                      },
                    ),
                  ],
                ),
                // 这句只在条漫连续滚动（方向确实不生效）时出现，单页模式下不提示。
                if (flow) ...[
                  const SizedBox(height: 6),
                  Text(
                    '条漫连续滚动模式下方向不生效',
                    style: c.micro11.copyWith(color: c.text3),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  '页面适配',
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
                      label: '整页',
                      compact: true,
                      active: !p.fitWidth,
                      onTap: () {
                        p.fitWidth = false;
                        p.changed();
                        setState(() => _offset = Offset.zero);
                      },
                    ),
                    const SizedBox(width: 8),
                    YmChip(
                      style: YmChipStyle.pill,
                      pressKind: YmPressKind.solid,
                      label: '适应宽度',
                      compact: true,
                      active: p.fitWidth,
                      onTap: () {
                        p.fitWidth = true;
                        p.changed();
                        setState(() => _offset = Offset.zero);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '遮罩强度',
                  style: TextStyle(
                    fontSize: YmFont.sub13,
                    fontWeight: FontWeight.w800,
                    color: c.text,
                  ),
                ),
                Slider(
                  value: p.maskOpacity,
                  max: 0.6,
                  activeColor: c.brand,
                  inactiveColor: c.fill,
                  onChanged: (v) {
                    p.maskOpacity = v;
                    p.changed();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _modeChip(BuildContext ctx, String label, YmMangaMode mode) {
    final p = YmMangaPrefs.instance;
    return YmChip(
      style: YmChipStyle.pill,
      pressKind: YmPressKind.solid,
      label: label,
      compact: true,
      active: p.mode == mode,
      onTap: () {
        if (p.mode == mode) return;
        final wasFlow = _flowMode;
        p.mode = mode;
        p.changed();
        final nowFlow = _flowMode;
        if (wasFlow != nowFlow) {
          setState(() {
            _drag = 0;
            _resetFlowZoom();
            if (nowFlow) {
              _flowAlignPage = _page;
            } else {
              _resetZoom();
            }
          });
        }
      },
    );
  }

  /* --------------------------------- UI --------------------------------- */

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: c.bg,
      body: AnimatedBuilder(
        animation: YmMangaPrefs.instance,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            _lastWidth = size.width;
            if (_flowEstimateH <= 0) _flowEstimateH = size.width * 1.9;
            if (_flowMode) _alignFlow(size.width);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: _flowMode
                      ? _flowBody(size)
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (_) => _stopPanInertia(),
                          onTapUp: (d) => _onTapUp(d, size),
                          onDoubleTapDown: (d) => _onDoubleTapDown(d, size),
                          onDoubleTap: () {},
                          onScaleStart: (d) => _onScaleStart(d, size),
                          onScaleUpdate: (d) => _onScaleUpdate(d, size),
                          onScaleEnd: (d) => _onScaleEnd(d, size),
                          child: _zoomed ? _zoomedPage(size) : _rail(size),
                        ),
                ),
                IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                        alpha: YmMangaPrefs.instance.maskOpacity),
                  ),
                ),
                if (_needLogin || (!_flowMode && _error != null && !_loading))
                  _errorOverlay(c),
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
                        child: YmTopBar(
                          title: widget.detail.title,
                          subtitle: _chapter.title,
                          leading: const YmBackButton(),
                          trailing: YmTextAction(
                            label: '详情',
                            // 同小说阅读器：进阅读器必经详情页 ⇒ 上一页必是详情，pop 即回。
                            onTap: () => Navigator.of(context).maybePop(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
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
                        child: Container(
                          padding: EdgeInsets.fromLTRB(YmLayout.pagePad, 10, YmLayout.pagePad, bottom + 10),
                          decoration: BoxDecoration(
                            color: c.card,
                            border: Border(top: BorderSide(color: c.border)),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!_flowMode && totalPages > 1)
                                YmReaderPageSlider(
                                  value: math.min(_page, totalPages).toDouble(),
                                  total: totalPages,
                                  onDone: _goPage,
                                ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: _BarCell(label: '目录', onTap: _openToc),
                                  ),
                                  Expanded(
                                    child: SizedBox(
                                      height: 44,
                                      child: Center(
                                        child: Text(
                                          _flowMode && _page > totalPages
                                              ? '本话完'
                                              : '$_page / $totalPages',
                                          // 页码读数＝说明文字：不写字重，落回 sub13 的 400。
                                          // 同排的「目录 / 加书签 / 设置」是控件标签（w700），
                                          // 层级正好靠这一轻一重拉开。
                                          style: c.sub13.copyWith(color: c.text2),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: _BarCell(
                                      label: _pinned ? '取消书签' : '加书签',
                                      onTap: _bookmark,
                                      active: _pinned,
                                    ),
                                  ),
                                  Expanded(
                                    child:
                                        _BarCell(label: '设置', onTap: _openSettings),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _errorOverlay(YmColors c) {
    return Positioned.fill(
      child: ColoredBox(
        color: c.bg.withValues(alpha: 0.94),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: YmLayout.pagePad),
            child: _needLogin
                ? const YmStateView(
                    title: '登录后使用',
                    desc: '登录百合会后即可阅读漫画。',
                  )
                : YmStateView(
                    title: '这一页没加载出来',
                    desc: _error,
                    actionLabel: '重试',
                    onAction: () => _load(_page, force: true),
                  ),
          ),
        ),
      ),
    );
  }

  /* ------------------------------ 单页渲染 ------------------------------ */

  Widget _rail(Size size) {
    final w = size.width;
    final h = size.height;
    final d = _drag;
    // scale=1 时 offset 就是长图的纵向滚动（contain 下恒为居中值）
    final off = _clampToBase(_offset, size, 1);
    // ltr：prev 在左、next 在右；rtl 镜像（next 在左）。
    final prevLeft = (_rtl ? w : -w) + d;
    final nextLeft = (_rtl ? -w : w) + d;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_page > 1)
            Positioned(
              left: prevLeft,
              top: 0,
              width: w,
              height: h,
              child: _pageCell(_page - 1, size),
            ),
          if (_page < _maxPage)
            Positioned(
              left: nextLeft,
              top: 0,
              width: w,
              height: h,
              child: _pageCell(_page + 1, size),
            ),
          Positioned(
            left: d,
            top: 0,
            width: w,
            height: h,
            child: _pageCell(_page, size, offset: off),
          ),
        ],
      ),
    );
  }

  Widget _zoomedPage(Size size) {
    final w = size.width;
    final h = size.height;
    final d = _drag;
    final off = _clampToBase(_offset, size, _scale);
    // 边界二滑时，整张放大页跟着手指滑出，邻页（未缩放）从侧边推进来；
    // 沿用页轨的左右摆放规则，RTL 自动镜像。
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (d != 0 && _page > 1)
            Positioned(
              left: (_rtl ? w : -w) + d,
              top: 0,
              width: w,
              height: h,
              child: _pageCell(_page - 1, size),
            ),
          if (d != 0 && _page < _maxPage)
            Positioned(
              left: (_rtl ? -w : w) + d,
              top: 0,
              width: w,
              height: h,
              child: _pageCell(_page + 1, size),
            ),
          Positioned(
            left: d,
            top: 0,
            width: w,
            height: h,
            child: ClipRect(
              child: Transform.translate(
                offset: off,
                child: Transform.scale(
                  scale: _scale,
                  // 放大时内容不能先裁到视口：长图要能连续平移到屏外；
                  // 视口裁剪交给外层 ClipRect（在缩放之后）。
                  child: _pageView(_page, size),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一页的视口格：内容按图片实际矩形排布，平移后再裁到格内。
  Widget _pageCell(int page, Size size, {Offset offset = Offset.zero}) {
    return ClipRect(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Transform.translate(
          offset: offset,
          child: _pageView(page, size),
        ),
      ),
    );
  }

  Widget _pageView(int page, Size size) {
    final c = YmScope.of(context).colors;
    if (page > totalPages) {
      // 章末过渡卡（虚拟页）：先看清下一话是什么，再决定跳不跳。
      return _chapterEndCard(size, c);
    }
    if (page < 1) {
      return ColoredBox(color: c.bg);
    }
    final url = _urls[page];
    final base = _baseRect(page, size);

    return ColoredBox(
      color: c.bg,
      child: url == null
          ? Center(
              child: _loading
                  ? Text(
                      '正在读取第 $page 页…',
                      style:
                          TextStyle(fontSize: YmFont.small12, color: c.text2),
                    )
                  : const SizedBox.shrink(),
            )
          : Stack(
              // 长图要能画到视口外，由 _pageCell 的 ClipRect 统一裁剪
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: base.left,
                  top: base.top,
                  width: base.w,
                  height: base.h,
                  child: _ReaderImage(
                    key: ValueKey('$url#$_imgNonce'),
                    url: url,
                    // 本机图（同步查，目录没就绪 / 没下载过 = null）：有就只读本机
                    local: YmCache.instance.peekImageFile(_chapter.id, page),
                    fit: BoxFit.contain,
                    width: base.w,
                    height: base.h,
                    onDecoded: (sz) => _onImageDecoded(page, sz),
                    // 阅读侧图片源对 Referer 敏感：带了会被拒；Flutter 默认不发，不要加
                    onRetry: () => _load(page, force: true),
                  ),
                ),
              ],
            ),
    );
  }

  void _onImageDecoded(int page, Size sz) {
    if (_natural[page] != sz) {
      _natural[page] = sz;
      // 缓存命中时监听器会在 build 阶段同步回调，延后一帧再刷新版式
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    if (page != 1 || _formKnown) return;
    // 形式未知：按第 1 页宽高比兜底判条漫（uni 版 setNatural 同口径）。
    if (sz.height / math.max(1, sz.width) > 1.6) {
      setState(() {
        _formKnown = true;
        _autoFlow = true;
      });
    }
  }

  Widget _chapterEndCard(Size size, YmColors c) {
    final next = _nextChapterRef;
    return Container(
      width: size.width,
      height: size.height,
      color: c.bg,
      padding: EdgeInsets.fromLTRB(
          24, MediaQuery.paddingOf(context).top + 60, 24, 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${_chapter.title} · 完',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: YmFont.strong17,
              fontWeight: FontWeight.w800,
              color: c.text,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            next == null ? '已经是最新一话了' : '下一话：${next.title}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: YmFont.small12, color: c.text2),
          ),
          const SizedBox(height: 22),
          if (next != null)
            YmButton(
              kind: YmButtonKind.primary,
              label: '继续下一话',
              onTap: () => _goChapter(next),
            ),
          const SizedBox(height: 10),
          YmPressable(
            kind: YmPressKind.row,
            radius: BorderRadius.circular(YmRadius.chip),
            onTap: _openToc,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                '回目录',
                style: TextStyle(fontSize: YmFont.body14, color: c.text2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /* ------------------------------ 条漫渲染 ------------------------------ */

  Widget _flowBody(Size size) {
    final itemCount = totalPages + 1; // 页 + 章末卡
    final list = ListView.builder(
      key: ValueKey('flow:${_chapter.id}'),
      controller: _flowCtrl,
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      addAutomaticKeepAlives: false,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final page = index + 1;
        if (page > totalPages) {
          return SizedBox(
            width: size.width,
            height: size.height,
            child: _chapterEndCard(size, YmScope.of(context).colors),
          );
        }
        final near = (page - _page).abs() <= 1;
        _ensurePage(page, user: near);
        final url = _urls[page];
        return _FlowImage(
          key: ValueKey('$url|$page|${_chapter.id}'),
          url: url,
          // 与分页形态同一套取值（page 1 基，写盘也是 1 基，别错位）
          local: YmCache.instance.peekImageFile(_chapter.id, page),
          width: size.width,
          height: _flowHeightOf(page, size.width),
          onSize: (sz) {
            final h = size.width * sz.height / math.max(1, sz.width);
            if (_flowHeights[page] == h) return;
            // 缓存命中时图片监听器会在 build 阶段同步回调，延后一帧再改高度
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _flowHeights[page] == h) return;
              setState(() => _flowHeights[page] = h);
            });
          },
          onRetry: () => _ensurePage(page, force: true, user: true),
        );
      },
    );

    // 条漫：点按切工具栏；两指一落下就由自定义识别器抢占（列表的纵向拖动
    // 在 18px 就接受，真机捏合几乎都有焦点漂移，默认识别器会输）。
    // 纵向移动始终交给列表滚动 —— 它就是放大后的纵向平移，带系统惯性、
    // 能一路滚完整章；放大后只有横向拖动走这里的平移。
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.depth == 0 && n is ScrollUpdateNotification) {
          _syncFlowPage(size.width, size.height);
          // 用户主动滚动时收起浮层；程序性跳页（进度对齐）不收。
          if (n.dragDetails != null && _chrome) {
            _setChrome(false);
          }
        }
        return false;
      },
      child: Listener(
        // 原始监听器不受手势竞技场影响：列表赢走纵向拖动时，这里仍能同时
        // 拿到横向位移，斜拖就能两轴并行。
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onFlowPointerDown,
        onPointerMove: (e) => _onFlowPointerMove(e, size),
        onPointerUp: (e) => _onFlowPointerUp(e, size),
        onPointerCancel: _onFlowPointerCancel,
        child: RawGestureDetector(
          gestures: <Type, GestureRecognizerFactory>{
            _FlowScaleGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                    _FlowScaleGestureRecognizer>(
              () => _FlowScaleGestureRecognizer(debugOwner: this),
              (r) {
                r.onStart = _onFlowScaleStart;
                r.onUpdate = (d) => _onFlowScaleUpdate(d, size);
                r.onEnd = (d) => _onFlowScaleEnd(d, size);
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (_) => _setChrome(!_chrome),
            onDoubleTapDown: (d) => _onFlowDoubleTapDown(d, size),
            onDoubleTap: () {},
            child: ClipRect(
              child: Transform.translate(
                offset: _flowOffset,
                child: Transform.scale(
                  scale: _flowScale,
                  child: list,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 条漫用的缩放识别器：第二根手指落下就接受手势。
///
/// 默认的 `ScaleGestureRecognizer` 要等 span 变化才进 arena，而并列的 ListView
/// 纵向拖动在 18px 位移就接受；真机捏合通常伴随焦点上下漂移，于是列表先赢，
/// 表现为「双指缩放极难触发」。单指不受影响：只有 2 个指针时才抢先接受。
class _FlowScaleGestureRecognizer extends ScaleGestureRecognizer {
  _FlowScaleGestureRecognizer({super.debugOwner});

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event is PointerDownEvent && pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }
}

/* ======================================================================== */
/*                              图片组件                                     */
/* ======================================================================== */

/// 订阅图片解码流拿原始宽高（uni 版 `@load` / `getImageInfo` 的原生等价物）。
///
/// 第二期 2F（2026-11-24）：手动下载过的一话，页图在本机，[local] 非空就**只**
/// 用本地文件渲染（断网 / 飞机模式下也能从头翻到尾），否则照旧走网络。
/// ⚠ 尺寸订阅（[_ReaderImageState._resolveSize]）与实际渲染必须是**同一套**
/// 图源判断：只改一处会让版式按网络图算、画面却是本机图，第 1 页判条漫时尤其会错。
class _ReaderImage extends StatefulWidget {
  const _ReaderImage({
    super.key,
    required this.url,
    required this.fit,
    required this.onDecoded,
    required this.onRetry,
    this.local,
    this.width,
    this.height,
  });

  final String url;

  /// 本机页图（`YmCache.peekImageFile` 同步取，null = 没下载过）。
  final File? local;
  final BoxFit fit;
  final double? width;
  final double? height;
  final void Function(Size) onDecoded;
  final VoidCallback onRetry;

  @override
  State<_ReaderImage> createState() => _ReaderImageState();
}

class _ReaderImageState extends State<_ReaderImage> {
  bool _autoRetried = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveSize();
  }

  @override
  void didUpdateWidget(covariant _ReaderImage old) {
    super.didUpdateWidget(old);
    // 换了图源（URL 变 / 本机图刚下来）就重新给「首次失败自动强刷」一次机会
    if (old.url != widget.url || old.local != widget.local) _autoRetried = false;
    _resolveSize();
  }

  void _resolveSize() {
    // 与 build 同一套判断：本地图优先，别让版式按网络图算
    final local = widget.local;
    final provider = local != null
        ? FileImage(local)
        : NetworkImage(widget.url) as ImageProvider<Object>;
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
      // 尺寸订阅不管错误：失败由 Image 的 errorBuilder 报（双份会重复弹错，
      // 测试里还会被当成「未处理的异常」把用例判红）。
      onError: (Object error, StackTrace? stack) {},
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

  /// 失败兜底：一行「图片加载失败 · 重试」，点了就走 [widget.onRetry]。
  ///
  /// [autoRetry] 只对网络分支开：签名 URL 过期靠重取页原文能自愈；本地文件读
  /// 失败说明文件真坏了（或被删了），自动强刷只会白转一圈，直接交给人点。
  Widget _errorTile(BuildContext context, {required bool autoRetry}) {
    if (autoRetry && !_autoRetried) {
      _autoRetried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onRetry();
      });
    }
    return Center(
      child: YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.circular(YmRadius.chip),
        onTap: widget.onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            '图片加载失败 · 重试',
            style: TextStyle(
              fontSize: YmFont.body14,
              color: YmScope.of(context).colors.text2,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final local = widget.local;
    if (local != null) {
      // 本机图：没有下载进度可言（读盘毫秒级），所以不带 loadingBuilder
      return Image.file(
        local,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) =>
            _errorTile(context, autoRetry: false),
      );
    }
    return Image.network(
      widget.url,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      filterQuality: FilterQuality.medium,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                  value: progress.expectedTotalBytes == null
                      ? null
                      : progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!,
                ),
              ),
            ),
      errorBuilder: (context, error, stack) =>
          _errorTile(context, autoRetry: true),
    );
  }
}

/// 条漫流式里的一格：未知宽高时用估高占位，解码后按真实比例展开。
class _FlowImage extends StatelessWidget {
  const _FlowImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    required this.onSize,
    required this.onRetry,
    this.local,
  });

  final String? url;

  /// 本机页图（有就只读本机，不再走网络）。
  final File? local;
  final double width;
  final double height;
  final void Function(Size) onSize;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    if (url == null) {
      return Container(
        width: width,
        height: height,
        color: c.bg,
        alignment: Alignment.center,
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
        ),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: _ReaderImage(
        url: url!,
        local: local,
        fit: BoxFit.fitWidth,
        width: width,
        height: height,
        onDecoded: onSize,
        onRetry: onRetry,
      ),
    );
  }
}

/* ======================================================================== */
/*                              工具栏部件                                   */
/* ======================================================================== */

class _BarCell extends StatelessWidget {
  const _BarCell({required this.label, required this.onTap, this.active = false});

  final String label;
  final VoidCallback onTap;

  /// 已生效的开关（书签已钉在这一页）—— 品牌色 + 加重，与未生效的普通动作区分。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Center(
          child: Text(
            label,
            // 工具栏按钮标签＝控件标签：12px 显式 w700（默认已是 400）。
            // 选中态（书签已钉）只换 brandInk 色，不改字重。
            style: TextStyle(
              fontSize: YmFont.small12,
              fontWeight: FontWeight.w700,
              color: active ? c.brandInk : c.text2,
            ),
          ),
        ),
      ),
    );
  }
}

