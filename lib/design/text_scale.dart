import 'package:flutter/material.dart';

/// 字号策略（资产包 D1）：
/// - 内容文字（正文、标题、卡片里的字）完全跟随系统 textScaler；
/// - 定高件（胶囊 / 按钮 / 底栏 / 工具条）在子树内把上限钳到 [fixedMax]，
///   否则系统字号放大后会撑破固定高度（探针实测：2.0 时底栏溢出 3px）；
/// - 自绘字形（YmGlyph / 封面 SVG）不参与缩放；
/// - 允许长高的件（顶栏、列表行、卡片）不钳，让它们自然长高。
class YmTextScale {
  const YmTextScale._();

  static const double fixedMax = 1.5;

  /// 把定高控件子树的 textScaler 上限钳到 [maxScaleFactor]（默认 1.5）。
  static Widget clampFixed({
    required Widget child,
    double maxScaleFactor = fixedMax,
  }) {
    assert(maxScaleFactor > 0, 'maxScaleFactor 必须大于 0');
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxScaleFactor,
      child: child,
    );
  }
}
