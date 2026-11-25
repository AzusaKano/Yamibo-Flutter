import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../pressable.dart';
import '../text_scale.dart';
import '../theme.dart';
import '../tokens.dart';
import 'top_bar.dart';

/// 阅读器工具栏的一格动作（目录 / 阅读设置 / 加书签…）。
///
/// 按钮由调用方按列表交给 [YmReaderToolbar]，壳不写死格数：
/// 小说侧传三格，论坛侧（第十二期）按自己的动作传。
class YmReaderTool {
  const YmReaderTool({
    required this.label,
    required this.onTap,
    this.active = false,
    this.info = false,
  });

  final String label;
  final VoidCallback onTap;

  /// 这一格是否处于「已开启」态（如这一章已经钉着书签）。
  /// 文案由调用方按站点原版口径决定（「加书签」⇄「取消书签」），壳不推断。
  final bool active;

  /// 只显示读数、不可点的格子（第十六期）：页码读数是**说明文字**
  /// （sub13 / 400，漫画 :1437-1448 同款，禁写字重——层级靠同排控件标签的
  /// w700 拉开），不包按压件。onTap 仍必填，info 格传空函数即可（约定不接动作）。
  final bool info;
}

/// 阅读器外壳：正文滚动区 + 沉浸式上下 chrome + 可选章末区。
///
/// 内容语义一概不碰：正文由调用方拼成一个 [body] 传进来（小说侧是段落，
/// 论坛侧届时是块渲染结果）。chrome 的显隐状态仍由调用方持有，
/// 点正文空白处时壳通过 [onChromeChanged] 把目标态抛回去，由调用方落状态并联动系统栏。
///
/// 翻页模式（第十五期）：调用方把整页 [pagedContent] 传进来就不包 ListView——
/// 正文自己管翻页与点按分区；`ScrollEndNotification` 仍会从这里冒出来
/// （PageView 落页稳定时也会发），`onScrollEnd` 记进度照常工作。
class YmReaderShell extends StatelessWidget {
  /// 顶部 chrome 占高（状态栏之外）：72 顶栏 + 进度条 14 + 6。
  /// 滚动与分页两种模式的正文预算同源，改一处两边一起变。
  static const double chromeTopExtent = 92.0;

  /// 底部 chrome 占高（安全区之外）：工具栏 52 + 6。
  static const double chromeBottomExtent = 58.0;

  const YmReaderShell({
    super.key,
    required this.controller,
    required this.progress,
    required this.title,
    this.subtitle,
    this.leading = const YmBackButton(),
    this.trailing,
    required this.body,
    this.footer,
    required this.tools,
    required this.chrome,
    required this.onChromeChanged,
    this.onScrollEnd,
    this.pagedContent,
    this.barSlider,
  });

  final ScrollController controller;
  final ValueListenable<double> progress;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// 滚动内容：调用方拼好的一整坨，壳只给它加留白。
  final Widget body;

  /// 分页正文（翻页模式）。给了就**直接渲染**，不再包 ListView：
  /// 翻页、点按分区、页码角标都是它自己的事；壳只剩 chrome 显隐与
  /// `onScrollEnd` 透传。不给（默认）走原来的滚动路径，一字节不变。
  final Widget? pagedContent;

  /// 底栏滑杆行（第十六期）：传了就在工具格 Row **上方**渲染（水平留 pagePad、
  /// 上留 10、与功能格间距 8，全部对齐漫画面板 :1414-1428 的口径）。只出现在
  /// 分页模式的覆盖层面板里——底栏变高纯覆盖，不进任何排版预算（全屏前提，
  /// [chromeBottomExtent] 是滚动模式 ListView padding 与分页预算的地板常量，
  /// 不因它而变）。不传（默认）= 单行工具格，逐字节不变。
  final Widget? barSlider;

  /// 章末区（如 [YmReaderEndBlock]）：由调用方决定放不放。
  final Widget? footer;

  final List<YmReaderTool> tools;
  final bool chrome;
  final ValueChanged<bool> onChromeChanged;

  /// 滚动停下（`ScrollEndNotification`）时回调，调用方用它记进度。
  final VoidCallback? onScrollEnd;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;

    // 顶部（状态栏 + 72 + 进度条 14 + 6）与底部（工具栏 52 + 安全区 + 6）
    // 的预留放在 ListView 的 padding 里：它属于滚动内容，不缩小视口。
    // 显隐只动覆盖层，阅读区高度与滚动位置都不变。
    final contentTop = topInset + chromeTopExtent;
    final contentBottom = chromeBottomExtent + bottomSafe;

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChromeChanged(!chrome),
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                onScrollEnd?.call();
                return false;
              },
              // 分页正文直接渲染（它自己的点按分区在内层，会赢下手势 arena，
              // 外壳这颗 onTap 不会双触发）；默认仍走滚动路径。
              child:
                  pagedContent ??
                  ListView(
                    controller: controller,
                    padding: EdgeInsets.fromLTRB(
                      YmLayout.pagePad,
                      contentTop,
                      YmLayout.pagePad,
                      contentBottom,
                    ),
                    children: [body, ?footer],
                  ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              ignoring: !chrome,
              child: AnimatedSlide(
                offset: chrome ? Offset.zero : const Offset(0, -1),
                duration: YmMotion.screen,
                curve: YmMotion.screenCurve,
                child: AnimatedOpacity(
                  opacity: chrome ? 1 : 0,
                  duration: YmMotion.screen,
                  child: ColoredBox(
                    color: c.bg,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        YmTopBar(
                          title: title,
                          subtitle: subtitle,
                          leading: leading,
                          trailing: trailing,
                        ),
                        YmReaderProgressBar(progress: progress),
                      ],
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
              ignoring: !chrome,
              child: AnimatedSlide(
                offset: chrome ? Offset.zero : const Offset(0, 1),
                duration: YmMotion.screen,
                curve: YmMotion.screenCurve,
                child: AnimatedOpacity(
                  opacity: chrome ? 1 : 0,
                  duration: YmMotion.screen,
                  child: YmReaderToolbar(tools: tools, slider: barSlider),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class YmReaderProgressBar extends StatelessWidget {
  const YmReaderProgressBar({super.key, required this.progress});

  final ValueListenable<double> progress;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YmLayout.pagePad,
        0,
        YmLayout.pagePad,
        12,
      ),
      child: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (context, v, _) => Container(
          height: 2,
          color: c.border,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: v.clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(color: c.accent),
          ),
        ),
      ),
    );
  }
}

class YmReaderEndBlock extends StatelessWidget {
  const YmReaderEndBlock({
    super.key,
    required this.prev,
    required this.next,
    required this.onPrev,
    required this.onNext,
    required this.onBack,
  });

  final YmChapterRef? prev;
  final YmChapterRef? next;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.only(top: 34, bottom: 20),
      padding: const EdgeInsets.only(top: 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: YmReaderEndButton(
                  label: prev != null ? '‹ 上一章' : '已经是第一章',
                  enabled: prev != null,
                  onTap: onPrev,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: YmReaderEndButton(
                  label: next != null ? '下一章 ›' : '已经是最后一章',
                  primary: true,
                  enabled: next != null,
                  onTap: onNext,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Center(
            child: YmPressable(
              kind: YmPressKind.row,
              radius: BorderRadius.circular(YmRadius.chip),
              onTap: onBack,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                // 文字动作＝控件标签：本页同类的「详情」用的是 sub13Strong（w700），
                // 这处原先靠 small12 的默认值（旧 500），新口径落 400 会读成说明文字，
                // 故显式补 w700（资产包文字动作档 T22-04 亦为 w700）。
                child: Text(
                  '返回目录',
                  style: c.small12.copyWith(
                    color: c.text2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class YmReaderEndButton extends StatelessWidget {
  const YmReaderEndButton({
    super.key,
    required this.label,
    this.primary = false,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool primary;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final bg = enabled ? (primary ? c.brand : c.fill) : c.fill;
    final fg = !enabled ? c.text3 : (primary ? Colors.white : c.text);

    final child = SizedBox(
      height: 46,
      child: Center(
        child: YmTextScale.clampFixed(
          child: Text(
            label,
            // 按钮标签取 w700（资产包 SlateButton 的内容字重）。
            // 禁用态不降字重，靠 fg 换成 text3 表达（资产包按钮禁用是整颗 .6 透明度，也不降重）。
            // ⚠ 裸 TextStyle 不写 fontWeight 会在 400，不会继承 preset。
            style: TextStyle(
              fontSize: YmFont.body14,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ),
      ),
    );

    if (!enabled) {
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(YmRadius.ctrl),
        ),
        child: child,
      );
    }

    return YmPressable(
      kind: primary ? YmPressKind.solid : YmPressKind.neutral,
      baseColor: bg,
      radius: BorderRadius.circular(YmRadius.ctrl),
      onTap: onTap,
      child: child,
    );
  }
}

class YmReaderToolbar extends StatelessWidget {
  const YmReaderToolbar({super.key, required this.tools, this.slider});

  final List<YmReaderTool> tools;

  /// 滑杆行（第十六期，可选）：见 [YmReaderShell.barSlider]。渲染在工具格
  /// Row 上方，水平留 pagePad、上留 10、与功能格间距 8（漫画面板口径）。
  final Widget? slider;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Container(
      padding: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: c.topbarBg,
        border: Border(top: BorderSide(color: c.topbarBd)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (slider != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                YmLayout.pagePad,
                10,
                YmLayout.pagePad,
                0,
              ),
              child: slider!,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              for (final t in tools)
                t.info
                    ? Expanded(
                        child: SizedBox(
                          height: 52,
                          child: Center(
                            child: Text(
                              t.label,
                              // 页码读数＝说明文字（漫画 :1445 同款）：sub13 /
                              // 400，禁写字重——同排控件标签是 w700，层级靠
                              // 这一轻一重拉开。
                              style: c.sub13.copyWith(color: c.text2),
                            ),
                          ),
                        ),
                      )
                    : YmReaderToolCell(
                        label: t.label,
                        onTap: t.onTap,
                        active: t.active,
                      ),
            ],
          ),
        ],
      ),
    );
  }
}

class YmReaderToolCell extends StatelessWidget {
  const YmReaderToolCell({
    super.key,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Expanded(
      child: YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.zero,
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Center(
            child: YmTextScale.clampFixed(
              child: Text(
                label,
                // 工具栏按钮标签＝控件标签：12px 按 §4.1 显式 w700（默认已是 400）。
                style: TextStyle(
                  fontSize: YmFont.small12,
                  fontWeight: FontWeight.w700,
                  color: c.text2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
