import 'api.dart';
import 'models.dart';
import 'write.dart';

/// 阅读器里的「书签」状态。
///
/// 站点把书签状态写在章节页 `#btnMark` 的文案上，而那个文案**不反映真实状态**
/// （2026-10-25 实测：加过书签之后章节页仍渲染「加书签」）⇒ 只能回列表里自己比对。
///
/// 判定只看**第 1 页**：`/my/bookmark` 没有「按作品过滤」的参数（条目里连 workId 都没有），
/// 为了找一条书签翻十几页不划算。误判的后果也都是安全的：
/// 真钉在第 2 页而这里判成「没钉」，点一下是把书签**移到当前章**（正是用户的本意），不会丢数据；
/// 反过来「判成已钉」只可能因为章节 id 真的一致 —— 那本来就是同一条书签。
Future<YmBookmarkFeed?> probeBookmarks() async {
  try {
    return await fetchBookmarks();
  } catch (_) {
    // 未登录 / 断网：当作「不知道」。按钮照样可点，点了会先提示登录。
    return null;
  }
}

/// 这一章是不是已经钉着书签。漫画要连页码一起对上 ——
/// 同章不同页时算「没钉」，于是点一下就是把书签更新到当前页。
bool bookmarkedAt(YmBookmarkFeed? feed, {required String chaptId, int? page}) {
  if (feed == null) return false;
  for (final it in feed.items) {
    if (it.chaptId != chaptId) continue;
    if (page != null && it.page != page) continue;
    return true;
  }
  return false;
}

/// 把书签设成「钉在当前这一章」/「从当前这一章取消」。
///
/// ⚠ 站点的写接口是**翻转**，而且一本书只有一条书签（唯一性在「用户 × 作品」），
/// 传别的章节是**覆盖**不是取消 —— 所以只能靠 [pinned] 这个已知状态算出该发哪一种：
/// 已钉着当前章 = 取消（`pinnedChaptId` 传本章），没钉 = 加（传空，落到当前章）。
/// 真正的判定与拦截都在 [YmWrite.setBookmark] 里，这里只是把两个参数配好。
Future<YmWriteResult> setBookmarkAt({
  required String workId,
  required String chaptId,
  required bool manga,
  required bool pinned,
  int page = 1,
  String csrfToken = '',
}) {
  return YmWrite.setBookmark(
    workId: workId,
    chaptId: chaptId,
    manga: manga,
    on: !pinned,
    pinnedChaptId: pinned ? chaptId : '',
    page: page,
    csrfToken: csrfToken,
  );
}
