import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 底栏图标：直接使用站点自绘的 24×24 线性图标（含描摹版「我的」logo），
/// 不再用 Material 图标近似。颜色由外层传 currentColor 等价的色值。
class YmNavIcon extends StatelessWidget {
  const YmNavIcon({
    super.key,
    required this.name,
    required this.color,
    this.size = 24,
  });

  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
