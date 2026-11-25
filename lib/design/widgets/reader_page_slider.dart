import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// 页码滑杆：轨道 4px、滑块 14px，外层 30px 触摸热区；拖动只预览，松手才跳页。
///
/// 第十六期从漫画阅读器提升为共用件（母本 `manga_reader_page._PageSlider`，
/// 2026-11-21 用户拍板「提共用件、漫画侧换引用」）：视觉与交互**逐字节不变**——
/// 拖动过程只更新预览与品牌底白字气泡「x / n」（micro11 w700），松手 `onDone`
/// 才提交；点轨道（onTapDown）直接跳。value / onDone 都是 **1 基页码**，与漫画
/// 滑杆、`YmReaderPagedController.page` 同口径。
class YmReaderPageSlider extends StatefulWidget {
  const YmReaderPageSlider({
    super.key,
    required this.value,
    required this.total,
    required this.onDone,
  });

  final double value;
  final int total;
  final ValueChanged<int> onDone;

  @override
  State<YmReaderPageSlider> createState() => _YmReaderPageSliderState();
}

class _YmReaderPageSliderState extends State<YmReaderPageSlider> {
  bool _dragging = false;
  double _preview = 1;

  double _valueAt(double dx, double width) =>
      ((dx / width) * widget.total).clamp(1, widget.total).toDouble();

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final v = _dragging ? _preview : widget.value;
        final pct = (v / widget.total).clamp(0.0, 1.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => setState(() {
            _dragging = true;
            _preview = _valueAt(d.localPosition.dx, w);
          }),
          onHorizontalDragUpdate: (d) => setState(() {
            _preview = _valueAt(d.localPosition.dx, w);
          }),
          onHorizontalDragEnd: (_) {
            setState(() => _dragging = false);
            widget.onDone(_preview.round());
          },
          onTapDown: (d) => widget.onDone(_valueAt(d.localPosition.dx, w).round()),
          child: SizedBox(
            height: 30,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 13,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.border,
                      borderRadius: BorderRadius.circular(YmRadius.pill),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 13,
                  width: pct * w,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.brand,
                      borderRadius: BorderRadius.circular(YmRadius.pill),
                    ),
                  ),
                ),
                Positioned(
                  left: (pct * w - 7).clamp(0.0, w - 14),
                  top: 8,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.card,
                      border: Border.all(color: c.brand, width: 2),
                    ),
                  ),
                ),
                if (_dragging)
                  Positioned(
                    bottom: 26,
                    left: (pct * w - 32).clamp(0.0, w - 64),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.brand,
                        borderRadius: BorderRadius.circular(YmRadius.chip),
                      ),
                      child: Text(
                        '${_preview.round()} / ${widget.total}',
                        // 拖动时的页码气泡：实心品牌底 + 白字，是**徽标**不是说明文字，
                        // 与资产包实心小徽标一致（如 SlateBadge 实心档 w700/800），
                        // 11px 默认 400 在品牌底上会糊，故保留显式 w700。
                        style: TextStyle(
                          fontSize: YmFont.micro11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
