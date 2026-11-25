import 'package:flutter/material.dart';

import '../theme.dart';

/// 顶栏下面那根 2px 加载条（内置网页壳 / 详情页刷新共用）。
///
/// 取值与网页壳里的原写法**逐字一致**：`minHeight: 2`、`fillPlain` 底、`brand` 条，
/// 不确定进度（不接真实百分比——详情页刷新拿不到进度，编一个数字只会跳）。
///
/// 只表达「正在取一次网络」：首屏加载有骨架屏与「正在加载…」，不叠这根条。
class YmLoadBar extends StatelessWidget {
  const YmLoadBar({super.key});

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return LinearProgressIndicator(
      minHeight: 2,
      backgroundColor: c.fillPlain,
      color: c.brand,
    );
  }
}
