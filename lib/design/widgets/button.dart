import 'package:flutter/material.dart';

import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import '../text_scale.dart';

enum YmButtonKind { primary, tint, secondary }

class YmButton extends StatelessWidget {
  const YmButton({
    super.key,
    required this.label,
    this.onTap,
    required this.kind,
    this.expanded = false,
    this.icon,
    this.height = 48,
    this.fontSize,
  });

  final String label;
  final VoidCallback? onTap;
  final YmButtonKind kind;
  final bool expanded;
  final IconData? icon;
  final double height;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final (bg, fg) = switch (kind) {
      YmButtonKind.primary => (c.brand, Colors.white),
      YmButtonKind.tint => (c.brandTint, c.brandInk),
      // 资产包 T06-02 `.secondary{background:var(--brand-tint);color:var(--brand)}`（index.wxss:29）。
      YmButtonKind.secondary => (c.brandTint, c.brandInk),
    };

    final button = YmPressable(
      kind: YmPressKind.solid,
      baseColor: bg,
      radius: BorderRadius.circular(YmRadius.ctrl),
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.symmetric(
            // 母本 `.actions .primary{padding:0 18px}` / `.secondary{0 16px}`（index.wxss:201/212）。
            horizontal: kind == YmButtonKind.primary ? 18 : 16,
          ),
          child: YmTextScale.clampFixed(
            child: Row(
              mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: fontSize ?? YmFont.body15,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 确认弹窗里的浅底按钮：取消 = fill-plain，确认 = brand-tint，危险 = error-bg。
class YmDialogButton extends StatelessWidget {
  const YmDialogButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final bg = danger ? c.errorBg : (primary ? c.brandTint : c.fillPlain);
    final fg = danger ? c.errorText : c.brandInk;

    return YmPressable(
      kind: YmPressKind.solid,
      baseColor: bg,
      radius: BorderRadius.circular(YmRadius.ctrl),
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Center(
          child: YmTextScale.clampFixed(
            child: Text(
              label,
              style: TextStyle(
                // 资产包 T06-06：15·w700。
                fontSize: YmFont.body15,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
