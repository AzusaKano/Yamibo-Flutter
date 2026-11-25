import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';
import 'button.dart';

/// 统一状态卡，对齐 uni 的 `.state-card`：
/// margin 32/20、padding 28/20、标题 16/w750、说明 12 行高 1.65、按钮 160×42 品牌实心。
class YmStateView extends StatelessWidget {
  const YmStateView({
    super.key,
    required this.title,
    this.desc,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? desc;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 32, 20, 32),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: YmFont.strong16,
              fontWeight: FontWeight.w700,
              color: c.text,
            ),
          ),
          if (desc != null) ...[
            const SizedBox(height: 8),
            Text(
              desc!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: YmFont.small12,
                height: 1.65,
                color: c.text2,
              ),
            ),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 18),
            SizedBox(
              width: 160,
              child: YmButton(
                kind: YmButtonKind.primary,
                label: actionLabel!,
                onTap: onAction,
                height: 42,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class YmSkeleton extends StatelessWidget {
  const YmSkeleton({
    super.key,
    this.width,
    required this.height,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class YmSkeletonRows extends StatelessWidget {
  const YmSkeletonRows({super.key, this.count = 5});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: YmScope.of(context).colors.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
      ),
      child: Column(
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  YmSkeleton(width: 200, height: 13),
                  SizedBox(height: 8),
                  YmSkeleton(width: 110, height: 13),
                  SizedBox(height: 8),
                  YmSkeleton(width: 145, height: 13),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
