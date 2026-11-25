import 'package:flutter/material.dart';

import 'manga_detail_page.dart';
import 'novel_detail_page.dart';
import 'routes.dart';

/// 详情页一律按 id 打开：详情与目录由页面自己取，
/// 这样书架 / 历史 / 排行 / 搜索里点开的任何一个 id 都能进。
///
/// [resumeChaptId] / [resumePage] 只在**从在线书签进来**时传：书签上钉的位置就是
/// 用户心里的「接着读这里」，可能和本机历史不一样（本机读到第 10 章、书签钉在第 30 章）。
/// 详情页拿它当续读点，等本机真的写下新进度后自动交还给本地历史。
void openWork(
  BuildContext context, {
  required String id,
  required String title,
  bool manga = false,
  String resumeChaptId = '',
  int resumePage = 1,
}) {
  if (manga) {
    ymPush(
      context,
      MangaDetailPage(
        id: id,
        title: title,
        resumeChaptId: resumeChaptId,
        resumePage: resumePage,
      ),
    );
  } else {
    ymPush(
      context,
      NovelDetailPage(id: id, title: title, resumeChaptId: resumeChaptId),
    );
  }
}
