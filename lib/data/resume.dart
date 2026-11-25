import 'dart:math' as math;

import 'library.dart';
import 'models.dart';

/// 详情页「继续阅读」指向哪一章 / 哪一页。
class YmResumePoint {
  const YmResumePoint._({this.chapter, this.page = 1});

  /// 空 = 没有可续的（按钮显示「开始阅读」）。
  final YmChapterRef? chapter;

  /// 漫画页码；小说忽略。
  final int page;

  bool get has => chapter != null;
}

/// 算出详情页的续读点。两个来源，**书签优先**：
///
/// 1. [hintChaptId] —— 从在线书架（站内书签）进来时带的那一条。书签钉的位置就是
///    用户心里的「接着读这里」，和本机历史可能差很远（本机读到第 1 话、书签在第 5 话）。
/// 2. [history] —— 本机阅读历史，从别的入口（书架本地 / 历史 / 搜索）进来时用它。
///
/// 书签指的那一章若在目录里找不到（删章 / 换 id），退回本地历史 —— 总比退化成
/// 「开始阅读」好。页码跟着来源走：用书签那一条就用书签的页码。
YmResumePoint resolveResume({
  required List<YmChapterRef> chapters,
  String hintChaptId = '',
  int hintPage = 1,
  YmHistoryEntry? history,
}) {
  YmChapterRef? find(String id) {
    if (id.isEmpty) return null;
    for (final ch in chapters) {
      if (ch.id == id) return ch;
    }
    return null;
  }

  final hint = find(hintChaptId);
  if (hint != null) {
    return YmResumePoint._(chapter: hint, page: math.max(1, hintPage));
  }

  final local = find(history?.chapterId ?? '');
  if (local == null) return const YmResumePoint._();
  return YmResumePoint._(chapter: local, page: math.max(1, history?.page ?? 1));
}
