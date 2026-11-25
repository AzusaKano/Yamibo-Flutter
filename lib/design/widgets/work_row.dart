import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import 'top_bar.dart' show YmTag;

/// 小说列表行，对齐 uni `.work-row`：
/// 书名 + 状态标签 / 作者（· 授权，普通不显示）/ 更新时间 + 分类标签。
class YmWorkRow extends StatelessWidget {
  const YmWorkRow({super.key, required this.work, this.onTap});

  final YmWork work;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final license = work.license.isNotEmpty && work.license != '普通' ? work.license : '';

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    work.title,
                    style: TextStyle(
                      fontSize: YmFont.body14,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                      color: c.text,
                    ),
                  ),
                ),
                if (work.status.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  YmTag(work.status, brand: work.status == '连载中'),
                ],
              ],
            ),
            const SizedBox(height: 5),
            Text(
              [
                work.author.isEmpty ? '佚名' : work.author,
                if (license.isNotEmpty) license,
              ].join(' · '),
              style: TextStyle(
                fontSize: YmFont.small12,
                height: 1.5,
                color: c.text2,
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: Text(
                    work.updatedAt,
                    style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
                  ),
                ),
                if (work.cat.isNotEmpty) YmTag(work.cat),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 漫画列表行，字段与小说行一致（作者缺失时取上传者，再退「佚名」）。
class YmMangaRow extends StatelessWidget {
  const YmMangaRow({super.key, required this.item, this.onTap});

  final YmManga item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: TextStyle(
                      fontSize: YmFont.body14,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                      color: c.text,
                    ),
                  ),
                ),
                if (item.status.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  YmTag(item.status, brand: item.status == '连载中'),
                ],
              ],
            ),
            const SizedBox(height: 5),
            Text(
              item.author.isEmpty ? '佚名' : item.author,
              style: TextStyle(
                fontSize: YmFont.small12,
                height: 1.5,
                color: c.text2,
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.updatedAt,
                    style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
                  ),
                ),
                if (item.cat.isNotEmpty) YmTag(item.cat),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
