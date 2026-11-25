import 'package:flutter/material.dart';

import '../../dev/metrics.dart';
import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import 'nav_icon.dart';
import '../text_scale.dart';

/// 底栏五项（论坛 2026-11-13 拍板加第五项，前四项顺序与语义不动）。
/// 与 uni 版的最大差别：切换用 IndexedStack 保活，不再 reLaunch 重建页面。
class YmBottomNav extends StatelessWidget {
  const YmBottomNav({super.key, required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const _items = <(String, String)>[
    ('首页', 'home'),
    ('搜索', 'search'),
    ('书架', 'shelf'),
    ('论坛', 'chat'),
    ('我的', 'mine'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Container(
      padding: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: colors.topbarBg,
        border: Border(top: BorderSide(color: colors.topbarBd)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: _Cell(
                label: _items[i].$1,
                iconName: _items[i].$2,
                active: index == i,
                onTap: () {
                  if (index == i) return;
                  ymBeginProbe('tab', 'Tab 切换 → 该帧完成');
                  onChanged(i);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.iconName,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String iconName;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    final color = active ? colors.brandInk : colors.text3;

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.circular(14),
      probe: false,
      onTap: onTap,
      child: SizedBox(
        height: 56,
        child: YmTextScale.clampFixed(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              YmNavIcon(name: iconName, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                // 底栏标签＝控件标签，11px 按 §4.1 显式 w700（默认值是 400）。
                // 选中态只靠 brandInk 换色、不换字重——与资产包胶囊/行选中同一做法
                //（SlateChip 选中只改底与墨色，字重恒定）。原非选中档写 w600 不是声明值。
                style: TextStyle(
                  fontSize: YmFont.micro11,
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
