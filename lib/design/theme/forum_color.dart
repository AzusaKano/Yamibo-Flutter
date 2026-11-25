/// 论坛正文「作者自填颜色」限幅映射（0.1.35 · 第十期）。
///
/// 口径来自决策表 §六·1（2026-11-19 用户拍板，不许改）：
/// - **保留色相**（HSL 的 H / S），只动亮度；
/// - 与当前主题背景的对比度下限 `3.0`（WCAG 大字档），不到就抬 / 压亮度；
/// - 与背景**过近**的颜色（亮底白字那种剧透写法、暗底深字）不调色，直接出「剧透遮罩」；
/// - 不写死 `#ffffff` 判断——任何与背景几乎同色的作者色都走遮罩。
///
/// 纯函数：亮 / 暗两套主题只靠传入的背景色区分，单测两套各跑一遍。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 映射结果：[color] 为 null = 不改色（用正文默认色）；[spoiler] = 走剧透遮罩。
class ForumColorResult {
  const ForumColorResult({this.color, this.spoiler = false});

  final Color? color;
  final bool spoiler;

  @override
  String toString() => 'ForumColorResult(color: $color, spoiler: $spoiler)';
}

/// 作者色与正文底的对比度下限。
const double kForumMinContrast = 3.0;

/// 「与背景过近」判据：低于它就直接判剧透，不再尝试调色。
///
/// 取 1.35 的理由：正常可读的浅灰 / 深灰都在 1.5 以上；白底白字、黑底黑字
/// 这类「作者用它藏字」的组合实测都在 1.1 上下，中间留一档安全距离。
const double kForumSpoilerContrast = 1.35;

/// 作者色 `#rrggbb` + 当前背景色 → 可读色 / 遮罩判据。
ForumColorResult forumReadableColor(
  String hex,
  Color background, {
  double minContrast = kForumMinContrast,
  double spoilerContrast = kForumSpoilerContrast,
}) {
  final base = forumParseHexColor(hex);
  if (base == null) return const ForumColorResult();

  final ratio = forumContrastRatio(base, background);
  if (ratio < spoilerContrast) return const ForumColorResult(spoiler: true);
  if (ratio >= minContrast) return ForumColorResult(color: base);

  final hsl = HSLColor.fromColor(base);
  // 往「对比度更高」的一侧调：暗底上的深色提亮、亮底上的浅色压暗。
  // 不用「谁更亮」猜方向——暗底上的彩字与浅底上的中灰都会猜反。
  final up = forumContrastRatio(
    hsl.withLightness(math.min(1, hsl.lightness + 0.05)).toColor(),
    background,
  );
  final down = forumContrastRatio(
    hsl.withLightness(math.max(0, hsl.lightness - 0.05)).toColor(),
    background,
  );
  final brighten = up >= down;
  var lightness = hsl.lightness;
  for (var i = 0; i < 100; i++) {
    lightness += brighten ? 0.01 : -0.01;
    if (lightness <= 0 || lightness >= 1) break;
    final candidate = hsl.withLightness(lightness).toColor();
    if (forumContrastRatio(candidate, background) >= minContrast) {
      return ForumColorResult(color: candidate);
    }
  }
  // 调不出可读色（极低饱和的中间灰）：退回正文默认色，不硬塞原文色
  return const ForumColorResult();
}

/// `#rgb` / `#rrggbb` → [Color]；认不出返回 null（不编色值）。
Color? forumParseHexColor(String hex) {
  var v = hex.trim().toLowerCase();
  if (v.startsWith('#')) v = v.substring(1);
  if (v.length == 3) v = v.split('').map((c) => '$c$c').join();
  if (v.length != 6 || !RegExp(r'^[0-9a-f]{6}$').hasMatch(v)) return null;
  return Color(0xff000000 | int.parse(v, radix: 16));
}

/// WCAG 对比度（1–21）。
double forumContrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}
