import 'package:flutter/foundation.dart';

import '../../data/forum/forum_models.dart';

/// 「最近访问」板块胶囊。一期只在内存里记（重启清空，不假装是历史记录）；
/// 落盘与否等二期看使用情况再定，不先造一张表。
final ValueNotifier<List<ForumBoardRef>> forumRecentBoards =
    ValueNotifier<List<ForumBoardRef>>(<ForumBoardRef>[]);

void rememberForumBoardVisit(ForumBoardRef board) {
  final next = <ForumBoardRef>[board, ...forumRecentBoards.value
      .where((b) => b.fid != board.fid)];
  if (next.length > 10) next.removeRange(10, next.length);
  forumRecentBoards.value = next;
}
