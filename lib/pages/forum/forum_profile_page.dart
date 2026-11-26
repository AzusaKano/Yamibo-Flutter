import 'package:flutter/material.dart';

import '../../data/forum/forum_api.dart';
import '../../data/forum/forum_auth.dart' show ForumSession;
import '../../data/forum/forum_models.dart';
import '../../data/forum/forum_user.dart';
import '../../design/pressable.dart';
import '../../design/theme.dart';
import '../../design/tokens.dart';
import '../../design/widgets/async_view.dart';
import '../../design/widgets/forum/forum_profile_head.dart';
import '../../design/widgets/forum/forum_thread_row.dart';
import '../../design/widgets/lists.dart';
import '../../design/widgets/top_bar.dart';
import '../../design/ym_route.dart' show ymRoute;
import 'forum_login_page.dart';
import 'forum_thread_page.dart' show openForumThread;
import 'forum_web.dart' show openForumWeb, openForumWafVerifyPage;

/// 个人资料页（`home.php?mod=space&uid=N&mycenter=1&mobile=2`）。
///
/// [uid] 为空 = 我自己（用登录态里的 uid）。
///
/// 一屏东西全部来自站点：头卡（名字 / 用户组 / 最后访问）、三格、签名、
/// 资料表、TA 的主题首屏。**拿不到就不画**——缺一格少一格、缺一行少一行，
/// 不印 `-`、不印「暂无」、不补字段（站点资料页本来就没有帖子数 / 精华数）。
class ForumProfilePage extends StatefulWidget {
  const ForumProfilePage({super.key, this.uid = ''});

  final String uid;

  @override
  State<ForumProfilePage> createState() => _ForumProfilePageState();
}

class _ForumProfilePageState extends State<ForumProfilePage> {
  /// 主题区首屏条数（站点自己有分页，原生翻页未做，更多去网页看）。
  static const int _threadsOnFirstScreen = 10;

  final GlobalKey<YmAsyncState<_ProfileBundle>> _asyncKey =
      GlobalKey<YmAsyncState<_ProfileBundle>>();
  final GlobalKey _threadsKey = GlobalKey();

  Future<_ProfileBundle> _load() async {
    final profile = await fetchForumProfile(uid: widget.uid);
    var threads = const <ForumThreadSummary>[];
    try {
      threads = await fetchForumProfileThreads(
        profile.uid.isNotEmpty ? profile.uid : widget.uid,
      );
    } catch (_) {
      // 主题拿不到就当没有：资料本身是真的，不该被这一块拖成整页报错
      threads = const <ForumThreadSummary>[];
    }
    return _ProfileBundle(profile: profile, threads: threads);
  }

  /// 登录门回来重取：YmAsync 只监听阅读侧账号，论坛登录得自己喊一次。
  Future<void> _openLogin() async {
    await Navigator.of(context).push(
      ymRoute(const ForumLoginPage(), snapshot: false),
    );
    if (mounted) _asyncKey.currentState?.reload();
  }

  void _toThreads() {
    final anchor = _threadsKey.currentContext;
    if (anchor == null) return;
    Scrollable.ensureVisible(
      anchor,
      duration: YmMotion.screen,
      curve: YmMotion.screenCurve,
    );
  }

  void _openWeb(String path, String title) {
    openForumWeb(context, path: path, title: title);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const YmTopBar(leading: YmBackButton(), title: '个人资料'),
          Expanded(
            child: YmAsync<_ProfileBundle>(
              key: _asyncKey,
              load: _load,
              errorTitle: '资料加载失败',
              loginDesc: '登录后查看资料。',
              onLogin: _openLogin,
              onWaf: (ctx, reload) async {
                await openForumWafVerifyPage(ctx);
                reload();
              },
              builder: (context, data, reload) => _buildBody(context, data),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, _ProfileBundle data) {
    final p = data.profile;
    final stats = _buildStats(context, p);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      children: [
        YmForumProfileHead(profile: p),
        if (stats != null) ...[const SizedBox(height: 14), stats],
        const SizedBox(height: 14),
        _buildActions(
          context,
          p,
          self: _isSelf(p),
          hasThreads: data.threads.isNotEmpty,
        ),
        if (p.signature.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SignatureCard(text: p.signature),
        ],
        if (p.fields.isNotEmpty) ...[
          const SizedBox(height: 14),
          _FieldsCard(fields: p.fields),
        ],
        if (data.threads.isNotEmpty) ...[
          const SizedBox(height: 14),
          _buildThreads(context, p, self: _isSelf(p), threads: data.threads),
        ],
      ],
    );
  }

  /// 是不是「我自己」：页面自己印了 `设置` / `btn_exit` 就算，
  /// 另外 uid 与登录态一致也算——站点对 `mycenter=1` 会给 302 把参数丢掉，
  /// 自视角那一页不一定还带着这两个标记，只靠页面标记会把自己的页认成别人的。
  bool _isSelf(ForumProfile p) =>
      p.isSelf ||
      (p.uid.isNotEmpty && p.uid == ForumSession.account.value.uid);

  /// 三格：总积分 / 积分 / 对象。站点把「值」印在标签前，缺格整格不画——
  /// 一格都没有就整条不出现（不画空卡）。
  Widget? _buildStats(BuildContext context, ForumProfile p) {
    final c = YmScope.of(context).colors;
    final cells = <(String, int)>[
      if (p.totalPoints != null) ('总积分', p.totalPoints!),
      if (p.points != null) ('积分', p.points!),
      if (p.partner != null) ('对象', p.partner!),
    ];
    if (cells.isEmpty) return null;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: Row(
        children: [
          for (final (label, value) in cells)
            Expanded(
              child: Column(
                children: [
                  Text(
                    '$value',
                    style: TextStyle(
                      fontSize: YmFont.strong17,
                      fontWeight: FontWeight.w800,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 动作格：两列，自己的页是「设置资料 / 退出登录」，别人的页是
  /// 「主题 / 日志 / 短消息 / 加为好友」。
  ///
  /// 除「主题」是页内跳转，其余都走网页壳——资料页上的写操作要令牌，
  /// 而**别人**的资料页根本没有 formhash，只能在网页里做。
  Widget _buildActions(
    BuildContext context,
    ForumProfile p, {
    required bool self,
    required bool hasThreads,
  }) {
    final c = YmScope.of(context).colors;
    final uid = p.uid;
    final actions = <(String, VoidCallback?)>[];
    if (self) {
      actions.add((
        '设置资料',
        () => _openWeb('/home.php?mod=spacecp&mobile=2', '设置资料'),
      ));
      actions.add((
        '退出登录',
        p.formhash.isEmpty
            ? null
            : () => _openWeb(
                '/member.php?mod=logging&action=logout'
                '&formhash=${p.formhash}&mobile=2',
                '退出登录',
              ),
      ));
    } else {
      if (hasThreads) actions.add(('主题', _toThreads));
      if (uid.isNotEmpty) {
        actions.add((
          '日志',
          () => _openWeb(
            '/home.php?mod=space&uid=$uid&do=blog&mobile=2',
            '日志',
          ),
        ));
        actions.add((
          '短消息',
          () => _openWeb(
            '/home.php?mod=space&do=pm&subop=view&touid=$uid&mobile=2',
            '短消息',
          ),
        ));
        actions.add((
          '加为好友',
          () => _openWeb(
            '/home.php?mod=spacecp&ac=friend&op=add&uid=$uid'
            '&handlekey=addfriendhk_$uid&mobile=2',
            '加为好友',
          ),
        ));
      }
    }
    if (actions.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[];
    for (var i = 0; i < actions.length; i += 2) {
      if (i > 0) {
        rows.add(Divider(height: 1, thickness: 1, color: c.borderWeak));
      }
      final left = actions[i];
      final right = i + 1 < actions.length ? actions[i + 1] : null;
      rows.add(
        Row(
          children: [
            _actionCell(c, left.$1, left.$2),
            if (right != null) ...[
              Container(width: 1, height: 22, color: c.borderWeak),
              _actionCell(c, right.$1, right.$2),
            ] else
              const Spacer(),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: Column(children: rows),
    );
  }

  Widget _actionCell(YmColors c, String label, VoidCallback? onTap) {
    return Expanded(
      child: YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.circular(YmRadius.inner),
        onTap: onTap,
        enabled: onTap != null,
        child: SizedBox(
          height: 46,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: YmFont.body14,
                fontWeight: FontWeight.w700,
                color: onTap == null ? c.text3 : c.text,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// TA 的主题：首屏 10 条，点行进原生帖子页（与板块页同一入口）。
  Widget _buildThreads(
    BuildContext context,
    ForumProfile p, {
    required bool self,
    required List<ForumThreadSummary> threads,
  }) {
    final c = YmScope.of(context).colors;
    return Column(
      key: _threadsKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Text(
            self ? '我的主题' : 'TA 的主题',
            style: TextStyle(
              fontSize: YmFont.body15,
              fontWeight: FontWeight.w700,
              color: c.text,
            ),
          ),
        ),
        YmCardList(
          margin: EdgeInsets.zero,
          children: [
            for (final t in threads.take(_threadsOnFirstScreen))
              YmForumThreadRow(
                thread: t,
                onTap: () => openForumThread(context, t),
              ),
          ],
        ),
      ],
    );
  }
}

/// 资料 + 主题首屏：两次请求的结果装在一起交给界面。
class _ProfileBundle {
  const _ProfileBundle({required this.profile, required this.threads});

  final ForumProfile profile;
  final List<ForumThreadSummary> threads;
}

/// 文字动作（展开 / 收起），与帖子页「还有 N 条点评」同一档。
class _MoreAction extends StatelessWidget {
  const _MoreAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      radius: BorderRadius.circular(YmRadius.chip),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          label,
          style: TextStyle(
            fontSize: YmFont.small12,
            fontWeight: FontWeight.w700,
            color: c.brand,
          ),
        ),
      ),
    );
  }
}

/// 签名卡：非空才出现，超过 6 行折起来。
class _SignatureCard extends StatefulWidget {
  const _SignatureCard({required this.text});

  final String text;

  @override
  State<_SignatureCard> createState() => _SignatureCardState();
}

class _SignatureCardState extends State<_SignatureCard> {
  static const int _maxLines = 6;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final style = TextStyle(
      fontSize: YmFont.sub13,
      height: 1.7,
      color: c.text2,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 折几行由实际排版决定（不按字数猜）：量一遍 6 行放不放得下
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: style),
            maxLines: _maxLines,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          final overflows = painter.didExceedMaxLines;
          final folded = overflows && !_expanded;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '个人签名',
                style: TextStyle(
                  fontSize: YmFont.micro11,
                  fontWeight: FontWeight.w700,
                  color: c.text3,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                widget.text,
                style: style,
                maxLines: folded ? _maxLines : null,
                overflow: folded ? TextOverflow.ellipsis : TextOverflow.clip,
              ),
              if (overflows) ...[
                const SizedBox(height: 6),
                _MoreAction(
                  label: _expanded ? '收起' : '展开',
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 资料表：两列（标签 / 值），站点原文照排，默认 8 行，超出可展开。
class _FieldsCard extends StatefulWidget {
  const _FieldsCard({required this.fields});

  final List<ForumProfileField> fields;

  @override
  State<_FieldsCard> createState() => _FieldsCardState();
}

class _FieldsCardState extends State<_FieldsCard> {
  static const int _maxRows = 8;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final fold = widget.fields.length > _maxRows;
    final rows = fold && !_expanded
        ? widget.fields.take(_maxRows).toList()
        : widget.fields;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 14,
                endIndent: 14,
                color: c.borderWeak,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      rows[i].label,
                      style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      rows[i].value,
                      style: TextStyle(
                        fontSize: YmFont.sub13,
                        height: 1.5,
                        color: c.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (fold)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _MoreAction(
                  label: _expanded ? '收起' : '展开全部 ${widget.fields.length} 行',
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
