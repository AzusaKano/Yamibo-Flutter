import 'package:flutter/material.dart';

import '../../data/forum/forum_track.dart';
import '../../design/widgets/forum/forum_track_row.dart';
import '../../design/widgets/lists.dart' show YmCardList;
import '../../design/widgets/selection.dart' show YmTopBarAction;
import '../../design/widgets/sheet.dart' show showYmConfirm;
import '../../design/widgets/state_view.dart';
import '../../design/widgets/top_bar.dart';
import 'forum_thread_page.dart' show ForumThreadPage;
import '../routes.dart' show ymPush;

/// 论坛「我的」→ 阅读历史：展示本机打开过的帖子，按最近阅读倒序。
///
/// 不主动请求站点，只读 ForumTrackStore 的本地记录。游客也能进。
/// 清空只删未追帖记录，追帖及其进度保留。
class ForumHistoryPage extends StatelessWidget {
  const ForumHistoryPage({super.key});

  Future<void> _clear(BuildContext context) async {
    final ok = await showYmConfirm(
      context,
      title: '清空阅读历史',
      content: '只清除未追帖的记录，追帖会保留。',
      confirmText: '清空',
      danger: true,
    );
    if (ok != true) return;
    ForumTrackStore.instance.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: ForumTrackStore.instance,
        builder: (context, _) {
          final entries = ForumTrackStore.instance.records;
          return Column(
            children: [
              YmTopBar(
                leading: const YmBackButton(),
                title: '阅读历史',
                subtitle: '${entries.length} 条',
                trailing: entries.isEmpty
                    ? null
                    : YmTopBarAction(label: '清空', onTap: () => _clear(context)),
              ),
              Expanded(
                child: entries.isEmpty
                    ? ListView(
                        children: const [
                          YmStateView(
                            title: '还没有阅读记录',
                            desc: '打开过的帖子会出现在这里',
                          ),
                        ],
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 10),
                        children: [
                          YmCardList(
                            children: [
                              for (final rec in entries)
                                YmForumTrackRow(
                                  record: rec,
                                  onTap: () => _openWith(context, rec),
                                ),
                            ],
                          ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 与书架追帖行同一恢复口径：有进度回到保存楼层并提示，没有就第 1 页。
  /// context 由 [AnimatedBuilder] 的 builder 传入（那个才挂在小树里，可导航）。
  void _openWith(BuildContext context, ForumTrackRecord rec) {
    if (rec.lastPage > 0 && rec.lastPid.isNotEmpty) {
      ymPush(
        context,
        ForumThreadPage(
          tid: rec.tid,
          initialPage: rec.lastPage,
          anchorPid: rec.lastPid,
          resumeToast: true,
        ),
      );
      return;
    }
    ymPush(context, ForumThreadPage(tid: rec.tid));
  }
}
