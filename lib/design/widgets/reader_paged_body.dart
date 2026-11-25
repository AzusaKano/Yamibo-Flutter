import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// 分页引擎的遥控器（第十六期）：滑杆与页码读数的数据源 + 跳页出口。
///
/// 十五期的引擎只上报 percent，外部拿不到总页数 / 当前页，也调不动引擎——
/// 滑杆（[YmReaderPageSlider]）三样都需要。口径与漫画侧一致：
///
/// * [page] 是 **1 基**页码（漫画滑杆 / 读数口径），[pageCount] 含章末区页；
/// * [jumpTo] clamp 到 [1, pageCount]，±1 走翻页动画、远距直接落位
///   （照抄漫画 `_goPage`，2026-11-21 拍板）；
/// * 引擎在**装箱完成**与**页变化**时回填（postFrame 里 notifyListeners，
///   十五期引擎惯例：不许在 build 中调）。
class YmReaderPagedController extends ChangeNotifier {
  int _page = 1;
  int _pageCount = 0;

  /// 当前页（1 基）。没装箱时是 1（对齐漫画 totalPages 初始 1 的口径）。
  int get page => _page;

  /// 总页数（含章末区页）。没装箱时是 0——页数没拿到就不编页码。
  int get pageCount => _pageCount;

  /// 引擎落位出口，由引擎状态挂载（[_attach]）；遥控器自己不知道引擎。
  void Function(int page)? _jump;

  /// 跳页：clamp 到 [1, pageCount]；没装箱（pageCount = 0）是空操作。
  void jumpTo(int page) {
    if (_pageCount <= 0) return;
    _jump?.call(page.clamp(1, _pageCount));
  }

  /// 引擎接线（内部用）：挂 / 摘落位出口。
  void _attach(void Function(int page) jump) => _jump = jump;
  void _detach() => _jump = null;

  /// 引擎回填（内部用）：变了才通知，滑杆与页码读数靠这个跟手。
  void _sync({required int page, required int pageCount}) {
    if (page == _page && pageCount == _pageCount) return;
    _page = page;
    _pageCount = pageCount;
    notifyListeners();
  }
}

/// 文字阅读器的**左右翻页正文**（第十五期）。
///
/// 把调用方给的整章块流（[YmReaderPagedBody.blocks]，不含块间距）按当前视口
/// 切成整屏页，`PageView` 左右翻；点按三分区：左 1/3 上一页、右 1/3 下一页、
/// 中间呼出 / 收起 chrome。正文语义一概不碰——块怎么渲染由调用方的
/// [YmReaderPagedBody.buildPage] 决定（论坛侧是 YmForumBody 的切片，小说侧是段落）。
///
/// ## 全屏前提：布局对 chrome / 系统栏零耦合（2026-11-21 用户拍板）
///
/// 正文按**全屏**排版：预算 = 视口高 − 固定页边距。页边距取**设备安全区**：
/// 顶 = 状态栏内距（挖孔 / 圆角之上），底 = 导航栏内距 + 指示条带（页码角标），
/// 两侧都带 pagePad 地板兜底。**采样一次后整场冻结**——chrome 显隐联动沉浸
/// 模式（系统栏隐藏 / 显示），`MediaQuery.padding` 会跟着翻转，排版只要
/// 响应式跟随内距，每次开关工具栏都会整页回排（实测踩过），所以引擎只在
/// 首次装箱前采样，此后布局对 chrome / 系统栏显隐零耦合：工具栏与系统栏
/// 一律是覆盖层，收起时文字占满全屏，展开时盖在正文上，布局不动。
///
/// ## 分页原理：真实测量 + 块级装箱
///
/// `TextPainter` 量不了引用块 / 原位图 / 折叠块，所以整章块流在真实宽度下
/// **真实布局一遍**：测量树挂在屏幕外（`Positioned(left: -10000)`，够不着也
/// 看不见），量完一帧后沿 RenderFlex 的子件逐块取高度（不用 GlobalKey 挂块，
/// 测量树与页面树同挂不撞键）。块级装箱：整块不跨页，装不下的换页，
/// 页底留白可接受；单块比整页还高时它独占一页，页内 `SingleChildScrollView`
/// 兜底（正常装箱后滚不动，超高块可以滚，不会溢出报错）。
///
/// 测量树**常驻**：图片解码完、折叠块展开都会让高度漂移，靠
/// [YmReaderPagedBody.relayoutRevision] 把这些信号折进重排（论坛侧经
/// `YmForumBody.onBlockLayoutChanged` 接线）。重排按「当前页首块下标」
/// 找回位置，**不回第一页**。
///
/// ## 进度口径（与滚动模式互通）
///
/// 页 p / 共 n 页 ⇔ `percent = (p + 1) / n`（最后页 = 1.0，对齐「读到章末照样
/// 恢复到底部」的 2026-11-19 拍板；n ≤ 1 记 0）。恢复时
/// `p = (percent × n − 1).round()` 钳位，存档字段一个不碰。
class YmReaderPagedBody extends StatefulWidget {
  const YmReaderPagedBody({
    super.key,
    required this.blocks,
    required this.buildPage,
    required this.onPageChanged,
    required this.onChromeToggle,
    required this.resetKey,
    this.footer,
    this.gap = 8.0,
    this.initialPercent,
    this.relayoutRevision = 0,
    this.controller,
  });

  /// 整章块流（与滚动模式的正文同一份构建，但**不含**块间距——间距由
  /// [gap] 统一给，测量树里也是裸块）。空列表 = 没有正文（调用方给骨架兜底）。
  final List<Widget> blocks;

  /// 页正文构建：给定块切片 `[start, endExclusive)`，调用方拼出**可交互**的
  /// 版本（论坛侧传剧透外置态与 seqBase，保证剧透不跨页串键）。
  /// 返回的 widget 内部块间距必须与 [gap] 一致（论坛侧 YmForumBody 自带 8px）。
  final Widget Function(int start, int endExclusive) buildPage;

  /// 章末区（评分 / 点评 / 章末导航）：作为最后一个原子块接在正文之后，
  /// 跟着一起装箱；不拆分，超高时独占一页页内滚。
  final Widget? footer;

  /// 块间距（论坛侧 8，小说侧 fontSize × 0.85）。
  final double gap;

  /// 进度上报：当前页变化（含首包与重排落位）时回调 `(page + 1) / pageCount`。
  final ValueChanged<double> onPageChanged;

  /// 中间分区点按：呼出 / 收起 chrome（调用方联动沉浸系统栏）。
  final VoidCallback onChromeToggle;

  /// 章身份（章节 pid 等）。变了 = 换章 / 换状态：按 [initialPercent] 重开；
  /// 没变只重排（字号 / 转屏 / 块高度漂移）时**保位**。
  final Object resetKey;

  /// 恢复进章用的章内进度（0~1，语义与滚动模式的 `percent` 一致）。
  final double? initialPercent;

  /// 重排信号：调用方把「影响布局的偏好」折进来（字号 / 行距 / 块高度变化计数，
  /// 推荐传记录值如 `(fontSize, lineHeight, tick)`，== 是结构化比较）。
  /// 变了就重测重排（保位）；[resetKey] 也变了则以换章为准（应用 [initialPercent]）。
  final Object relayoutRevision;

  /// 遥控器（第十六期）：外部传进来就能读 [YmReaderPagedController.page] /
  /// [YmReaderPagedController.pageCount] 并 jumpTo（滑杆 / 页码读数用）。
  /// 不传则引擎自建自用（兜底，调用方拿不到引用）；换实例会被重新接线并回填。
  final YmReaderPagedController? controller;

  @override
  State<YmReaderPagedBody> createState() => _YmReaderPagedBodyState();
}

class _YmReaderPagedBodyState extends State<YmReaderPagedBody> {
  /// 首包重试上限：测量树个别帧没铺齐时按帧重试，别死在「全章一页」兜底上。
  static const _maxMeasureAttempts = 10;

  /// 页底指示条带（页码角标住这里），叠在导航栏安全区之上。
  static const double _indicatorStrip = 20.0;

  /// 页边距地板：安全区采样异常（冻结到 0）时，至少留出 pagePad 呼吸。
  static const double _marginFloor = YmLayout.pagePad;

  /// 测量树容器（只挂这一个 key，块本身不带 key：与页面树同挂也不会撞）。
  final GlobalKey _measureKey = GlobalKey();

  final PageController _page = PageController();

  /// 每页首块下标（footer 算最后一块，下标 = blocks.length）。
  List<int> _pageStarts = const <int>[];

  int _current = 0;
  double? _lastBudget;
  bool _packedOnce = false;
  int _measureAttempts = 0;

  /// 历史见过的最大系统栏内距（非响应式缓存：只涨不跌，触发重建也不回排）。
  double _topSeen = 0;
  double _bottomSeen = 0;

  /// 冻结的安全区页边距（-1 = 未冻结）。首次装箱前采样一次，此后整场固定：
  /// chrome 显隐联动沉浸模式，`MediaQuery.padding` 会翻转，排版响应式跟随
  /// 内距 = 每次开关工具栏整页回排（实测踩过），所以采样后不许再变。
  double _safeTop = -1;
  double _safeBottom = -1;

  /// 外接遥控器为空时自建一个（兜底：调用方没传就拿不到引用，纯自用）。
  YmReaderPagedController? _ownedCtrl;

  /// 遥控器（外接优先）：页码 / 页数在这里回填，jumpTo 从这里进来。
  YmReaderPagedController get _ctrl => widget.controller ?? _ownedCtrl!;

  /// 一帧内多次页变化只排一次 postFrame 回填（notifyListeners 不许在 build 中调）。
  bool _ctrlSyncQueued = false;

  /// 内容区宽度（与滚动模式 ListView 的 pagePad 同口径）。
  double get _contentWidth =>
      MediaQuery.sizeOf(context).width - YmLayout.pagePad * 2;

  /// 单页正文预算：**全屏减冻结的安全区页边距**，其余全是覆盖层。
  double _budget(double stackHeight) =>
      stackHeight - _safeTop - (_safeBottom + _indicatorStrip);

  /// 页 p / 共 n 页 ⇔ percent（n ≤ 1 记 0，恢复时回顶部，同一屏没有歧义）。
  double _percentOf(int page, int count) =>
      count <= 1 ? 0 : ((page + 1) / count).clamp(0.0, 1.0);

  /// percent → 页：`p = (percent × n − 1).round()` 钳位。
  /// 0 → 回顶（与 readerRestoreTarget 的「刚开头不恢复」一致），
  /// 1.0 → 最后页（读到章末照样到底部）。
  int _pageForPercent(double? percent, int count) {
    if (percent == null || count <= 0) return 0;
    if (!percent.isFinite || percent <= 0.001) return 0;
    return ((percent * count - 1).round()).clamp(0, count - 1);
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _ownedCtrl = YmReaderPagedController();
    _ctrl._attach(_jumpTo);
    _schedulePack(applyInitial: true);
  }

  @override
  void didUpdateWidget(covariant YmReaderPagedBody old) {
    super.didUpdateWidget(old);
    // 换了遥控器实例：旧的下岗、新的接上并回填当前值（回填走 postFrame）。
    if (!identical(widget.controller, old.controller)) {
      old.controller?._detach();
      _ctrl._attach(_jumpTo);
      _scheduleCtrlSync();
    }
    final lengthChanged = widget.blocks.length != old.blocks.length;
    // 换章 / 状态切换（骨架 → 正文）：章身份或块数变了，按 initialPercent 重开。
    final reset = widget.resetKey != old.resetKey || lengthChanged;
    // 只重排（字号 / 行距 / 图片解码 / 折叠 / 转屏）保位。
    final relayout =
        widget.relayoutRevision != old.relayoutRevision ||
        widget.gap != old.gap ||
        lengthChanged;
    if (reset || relayout) {
      _schedulePack(applyInitial: reset || !_packedOnce);
    }
  }

  @override
  void dispose() {
    _ctrl._detach();
    _ownedCtrl?.dispose();
    _page.dispose();
    super.dispose();
  }

  /// 帧后测量 + 装箱：布局落地才有 RenderBox size。
  void _schedulePack({required bool applyInitial}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureAndPack(applyInitial: applyInitial);
    });
  }

  void _measureAndPack({required bool applyInitial}) {
    // 冻结安全区：首次装箱前采样一次。进阅读器时 chrome 必然可见（系统栏在），
    // 采到的就是真实安全区；取历史峰值是防首帧内距未落地的保险，地板防
    // 异常设备冻结到 0 时文字顶进挖孔。冻结后不再采样（全屏前提的硬约束）。
    if (_safeTop < 0) {
      _safeTop = math.max(_topSeen, _marginFloor);
      _safeBottom = math.max(_bottomSeen, _marginFloor);
    }
    // 量测量树：RenderFlex（Column）的直接子件顺序即块序。
    final hs = <double>[];
    final ro = _measureKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      ro.visitChildren((child) {
        final box = child as RenderBox;
        if (box.hasSize) hs.add(box.size.height);
      });
    }
    final expected = widget.blocks.length + (widget.footer != null ? 1 : 0);
    if (hs.length != expected) {
      // 测量树还没铺齐（个别帧没布局）：按帧重试；耗尽才退「全章一页」兜底
      // （页内滚兜底总比白屏强，但不到万不得已不走）。
      if (++_measureAttempts < _maxMeasureAttempts) {
        _schedulePack(applyInitial: applyInitial);
        return;
      }
      setState(() {
        _pageStarts = widget.blocks.isEmpty ? const <int>[] : const <int>[0];
        _packedOnce = true;
      });
      // 这里本就在 postFrame 里：页数变了照样回填遥控器，别让读数停在旧值。
      _ctrl._sync(page: _current + 1, pageCount: _pageStarts.length);
      return;
    }
    _measureAttempts = 0;
    final budget = _budget(_stackHeight());
    _applyPack(hs, budget, applyInitial: applyInitial);
  }

  double _stackHeight() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.size.height > 0) {
      return box.size.height;
    }
    return MediaQuery.sizeOf(context).height;
  }

  /// 贪心装箱：整块不跨页；单块超预算放它独占一页（j > i 才断）。
  void _applyPack(
    List<double> hs,
    double budget, {
    required bool applyInitial,
  }) {
    final n = hs.length;
    final starts = <int>[];
    var i = 0;
    while (i < n) {
      starts.add(i);
      var h = 0.0;
      var j = i;
      while (j < n) {
        final bh = hs[j] + (j > i ? widget.gap : 0);
        if (h + bh > budget && j > i) break;
        h += bh;
        j++;
      }
      i = j;
    }
    final target = applyInitial
        ? _pageForPercent(widget.initialPercent, starts.length)
        : _pageForBlock(_firstBlockOfCurrent(), starts);
    setState(() {
      _pageStarts = starts;
      _packedOnce = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_page.hasClients && (_page.page ?? 0).round() != target) {
        _page.jumpToPage(target);
      }
      if (_current != target) {
        setState(() => _current = target);
      }
      // 装箱后页数可能变（字号 / 行距 / 转屏 / 章末区）：回填遥控器。这里
      // 本来就是 postFrame，notifyListeners 合法（十五期惯例，不许在 build 中调）。
      _ctrl._sync(page: _current + 1, pageCount: _pageStarts.length);
      widget.onPageChanged(_percentOf(_current, _pageStarts.length));
    });
  }

  /// 重排保位：当前页首块下标。
  int _firstBlockOfCurrent() =>
      _current < _pageStarts.length ? _pageStarts[_current] : 0;

  /// 块下标 → 页码：落在哪一页的 `[start, nextStart)` 区间里。
  int _pageForBlock(int block, List<int> starts) {
    for (var p = 0; p < starts.length; p++) {
      final next = p + 1 < starts.length ? starts[p + 1] : 1 << 30;
      if (block >= starts[p] && block < next) return p;
    }
    return 0;
  }

  void _flip(int delta) {
    if (_pageStarts.isEmpty || !_page.hasClients) return;
    final cur = (_page.page ?? _current.toDouble()).round();
    final t = cur + delta;
    if (t < 0 || t >= _pageStarts.length) return;
    _page.animateToPage(
      t,
      duration: YmMotion.screen,
      curve: YmMotion.screenCurve,
    );
  }

  /// 滑杆跳页落位（口径照抄漫画 `_goPage` :410）：page 已由控制器 clamp 到
  /// [1, pageCount]；±1 走翻页动画（YmMotion.screen / screenCurve，与 _flip
  /// 同源），远距直接落位；落位后的进度上报走 onPageChanged 既有链路，存档
  /// 口径不变。chrome 显隐不碰（漫画侧跳完 chrome 保持展开，由调用方管）。
  void _jumpTo(int page) {
    if (_pageStarts.isEmpty || !_page.hasClients) return;
    final target = page - 1;
    final delta = target - (_page.page ?? _current.toDouble()).round();
    if (delta == 0) return;
    if (delta.abs() == 1) {
      _page.animateToPage(
        target,
        duration: YmMotion.screen,
        curve: YmMotion.screenCurve,
      );
    } else {
      _page.jumpToPage(target);
    }
  }

  /// 把当前页码回填给遥控器（页码读数 / 滑杆靠这个跟手）。页变化来自
  /// onPageChanged / 装箱落位，都不该在 build 里 notify：统一排到 postFrame。
  void _scheduleCtrlSync() {
    if (_ctrlSyncQueued) return;
    _ctrlSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrlSyncQueued = false;
      if (!mounted) return;
      _ctrl._sync(page: _current + 1, pageCount: _pageStarts.length);
    });
  }

  /// 点按三分区：左 1/3 上一页，右 1/3 下一页，中间呼出 / 收起 chrome。
  /// 链接 / 剧透 / 按钮的点按在最内层，手势 arena 里赢过这颗，不受影响。
  void _onTapUp(TapUpDetails d) {
    final w = MediaQuery.sizeOf(context).width;
    final x = d.localPosition.dx;
    if (x < w / 3) {
      _flip(-1);
    } else if (x > w * 2 / 3) {
      _flip(1);
    } else {
      widget.onChromeToggle();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final hasPages = _pageStarts.isNotEmpty;

    // 非响应式缓存安全区峰值：只涨不跌，改字段不触发重建，也不会引发回排
    // （响应式跟随 = 每次开关工具栏整页回排，见类注释）。
    final insets = MediaQuery.paddingOf(context);
    if (insets.top > _topSeen) _topSeen = insets.top;
    if (insets.bottom > _bottomSeen) _bottomSeen = insets.bottom;

    // 未冻结（首帧）时给占位边距：页面树此时还没铺出来（hasPages=false），
    // 真正的排版边距在冻结后与本帧的 Padding 同源。
    final topM = _safeTop < 0 ? _marginFloor : _safeTop;
    final bottomM = _safeBottom < 0 ? _marginFloor : _safeBottom;

    return LayoutBuilder(
      builder: (context, cons) {
        // 转屏 / 分屏：预算变了就重测重排（保位）。首帧走 initState 的首包。
        // 预算只含视口高与冻结的安全区边距，chrome / 系统栏显隐不进来。
        if (_safeTop >= 0) {
          final budget = _budget(cons.maxHeight);
          if (_packedOnce && _lastBudget != null && budget != _lastBudget) {
            _schedulePack(applyInitial: false);
          }
          _lastBudget = budget;
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            // 测量树：真实宽度 + 真实块，屏幕外布局（够不着、看不见、进不了语义树）。
            Positioned(
              left: -10000,
              top: 0,
              child: ExcludeSemantics(
                child: SizedBox(
                  width: _contentWidth,
                  child: Column(
                    key: _measureKey,
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final b in widget.blocks) b,
                      ?widget.footer,
                    ],
                  ),
                ),
              ),
            ),
            if (hasPages)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _onTapUp,
                child: PageView.builder(
                  controller: _page,
                  itemCount: _pageStarts.length,
                  onPageChanged: (p) {
                    setState(() => _current = p);
                    _scheduleCtrlSync();
                    widget.onPageChanged(_percentOf(p, _pageStarts.length));
                  },
                  itemBuilder: (context, p) {
                    final start = _pageStarts[p];
                    final end = p + 1 < _pageStarts.length
                        ? _pageStarts[p + 1]
                        : widget.blocks.length;
                    // 章末区只属于整章的**最后一页**。它按原子块装箱——挤不进
                    // 文字末页的剩余空间时会独占一页（_pageStarts 末项 =
                    // blocks.length），此时文字末页的 end 也是 blocks.length，
                    // 按 end 判就会渲染两次（0.1.39 真机发现：文字末页尾部出现
                    // 评分 / 上下章，翻页又见一次）。按「p 是不是最后一页」判：
                    // 末页 = 文字+章末 或 章末独占，二选一恰好一次。
                    final withFooter =
                        widget.footer != null && p == _pageStarts.length - 1;
                    // 全屏排版：冻结的安全区边距（与装箱预算同源），工具栏 /
                    // 系统栏展开时盖在这上面，页面布局不随显隐回排。
                    return Padding(
                      padding: EdgeInsets.fromLTRB(
                        YmLayout.pagePad,
                        topM,
                        YmLayout.pagePad,
                        bottomM + _indicatorStrip,
                      ),
                      child: SingleChildScrollView(
                        // 装箱正常时滚不动；单块超高（极端长引用）页内滚兜底
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (end > start) widget.buildPage(start, end),
                            if (withFooter) ...[
                              if (end > start) SizedBox(height: widget.gap),
                              widget.footer!,
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            // 页码角标：住在页底预留的指示条带里（固定位置，chrome 显隐不挪位）
            if (hasPages && _pageStarts.length > 1)
              Positioned(
                right: YmLayout.pagePad,
                bottom: bottomM + 2,
                child: Text(
                  '${_current + 1} / ${_pageStarts.length}',
                  style: TextStyle(
                    fontSize: YmFont.small12,
                    fontWeight: FontWeight.w700,
                    color: c.text3,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
