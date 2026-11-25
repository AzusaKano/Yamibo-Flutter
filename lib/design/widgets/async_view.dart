import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/http.dart';
import '../../data/session.dart';
import '../theme.dart';
import '../tokens.dart';
import 'button.dart';
import 'load_bar.dart';
import 'state_view.dart';

/// 统一的「异步取数」外壳：
/// - 载入中 → 骨架（或自定义占位）；
/// - 失败 → 加载失败 + 重试；
/// - 需要登录 → 整屏「登录后使用」，不露半截内容；
/// - 成功 → 交给 builder，并把 `reload` 传下去。
///
/// 口径来自 uni 版：页面不自己写 loading/error 分支，文案固定
/// 「正在加载…」/「加载失败」/「登录后使用」，不出现实现词。
class YmAsync<T> extends StatefulWidget {
  const YmAsync({
    super.key,
    required this.load,
    required this.builder,
    this.loading,
    this.onLogin,
    this.loginDesc,
    this.embedded = false,
    this.errorTitle = '加载失败',
    this.onWaf,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, VoidCallback reload) builder;
  final Widget? loading;
  final VoidCallback? onLogin;

  /// 登录态那一屏的说明行，按页面写清「什么需要登录」
  /// （书架在线 = 书签、收藏页 = 收藏），不写通用的一句话。
  final String? loginDesc;

  /// 嵌在别的可滚动容器里时置 true：载入/失败态不再套一层 ListView。
  final bool embedded;

  /// 失败态标题，按页面类型取（作品加载失败 / 列表加载失败 / 排行加载失败）。
  final String errorTitle;

  /// 被挑战层拦截时的收束动作（论坛侧用，见 forum_web.openForumWafVerifyPage
  /// 的取凭据与自动关页原理）：错误码 WAF 且传了回调时，错误态**只出一个「去验证」
  /// 按钮**（替代「重试」——重试拿不到新的凭据，这类验证只在浏览器引擎里能完成）。
  /// 点开网页壳，WebView 完成验证后自动关页，回调里做自动重试。
  /// 回调签名给 reload：从网页回来后调用即可自动重试。
  /// 阅读侧不传，行为不变。
  final void Function(BuildContext context, VoidCallback reload)? onWaf;

  @override
  State<YmAsync<T>> createState() => YmAsyncState<T>();
}

class YmAsyncState<T> extends State<YmAsync<T>> {
  late Future<T> _future;

  /// 登录态变化要自动重取：登录门上的「去登录」回来后页面才会出内容，
  /// 否则用户得自己再点一次刷新。
  bool _wasLoggedIn = YmSession.loggedIn;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
    YmSession.account.addListener(_onAccount);
  }

  @override
  void dispose() {
    YmSession.account.removeListener(_onAccount);
    super.dispose();
  }

  void _onAccount() {
    final now = YmSession.loggedIn;
    if (now == _wasLoggedIn) return;
    _wasLoggedIn = now;
    if (now && mounted) reload();
  }

  void reload() => setState(() => _future = widget.load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return widget.loading ??
              (widget.embedded ? const YmSkeletonRows(count: 4) : const YmLoadingView());
        }
        if (snap.hasError) {
          final err = snap.error;
          final login = err is YmHttpError && err.isLoginRequired;
          // 站方消息兜底（论坛侧 fetchForum* 抛出，code=SITE_MESSAGE）：关站/维护/
          // 公告是管理员自定义文案、重试无意义——标题换中性文案、不挂「重试」，
          // 只如实转发站点原文（2026-11-15 定调：不做重试承诺）。阅读侧不会抛
          // 这个码，行为不变。
          final siteMsg = err is YmHttpError && err.code == 'SITE_MESSAGE';
          final waf = !login && !siteMsg && err is YmHttpError && err.code == 'WAF' && widget.onWaf != null;
          final body = login
              ? YmLoginRequired(
                  // ⚠ 这里必须传 true：下面的分支已经把它包进 ListView 了
                  // （`widget.embedded` 为 false 时）。传 false 会让 YmLoginRequired
                  // 内部再套一个 ListView ⇒ "Vertical viewport was given unbounded height"。
                  embedded: true,
                  onLogin: widget.onLogin,
                  desc: widget.loginDesc,
                )
              : YmStateView(
                  title: siteMsg ? '论坛暂时无法访问' : widget.errorTitle,
                  desc: err is YmHttpError ? err.message : '请检查网络后重试',
                  // WAF：单按钮「去验证」收束（打开网页拿通行证自动关页自动重试，
                  // 0.1.19 拍板）；站方消息不挂按钮；其余照旧「重试」
                  actionLabel: siteMsg
                      ? null
                      : (waf ? '去验证' : '重试'),
                  onAction: siteMsg
                      ? null
                      : (waf ? () => widget.onWaf!(context, reload) : reload),
                );
          if (widget.embedded) return body;
          return ListView(padding: const EdgeInsets.only(bottom: 8), children: [body]);
        }
        return widget.builder(context, snap.data as T, reload);
      },
    );
  }
}

class YmLoadingView extends StatelessWidget {
  const YmLoadingView({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return ListView(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      children: [
        const YmSkeletonRows(count: 6),
        const SizedBox(height: 12),
        Center(
          child: Text(
            '正在加载…',
            style: c.micro11.copyWith(color: c.text3),
          ),
        ),
      ],
    );
  }
}

/// 需要登录：整屏提示（uni 的 `.login-gate`），不露表单与半截内容。
class YmLoginRequired extends StatelessWidget {
  const YmLoginRequired({
    super.key,
    this.onLogin,
    this.desc,
    this.embedded = false,
  });

  final VoidCallback? onLogin;

  /// 说明行：写清是**哪一项**需要登录（书签 / 收藏 / 搜索 …），
  /// 默认那句「登录百合会账号后即可使用这里」只在没指名时兜底。
  final String? desc;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final gate = Container(
      constraints: BoxConstraints(minHeight: embedded ? 300 : 420),
      padding: const EdgeInsets.fromLTRB(40, 40, 40, 60),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '登录后使用',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: YmFont.title24,
              fontWeight: FontWeight.w800,
              color: c.text,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            desc ?? '登录百合会账号后即可使用这里。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: YmFont.small12,
              height: 1.6,
              color: c.text2,
            ),
          ),
          if (onLogin != null) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: 200,
              child: YmButton(label: '去登录', kind: YmButtonKind.primary, onTap: onLogin, height: 42, fontSize: YmFont.body14),
            ),
          ],
          // 这一屏**不放刷新**（2026-10-26 用户口径）：没登录时刷新也不会有数据，
          // 登录态变化由 YmAsync 自己监听 `YmSession.account` 重取，用不上手动重试。
        ],
      ),
    );
    if (embedded) return gate;
    return ListView(children: [gate]);
  }
}

/* ------------------------------------------------------------------------- */

/// 本地优先的异步外壳：**先画本机那份，再在后台换成在线版本**（第四期，2026-11-24）。
///
/// 为什么要它（详情页专用）：断网时靠本机副本秒开；有网时也不空等转圈 ——
/// 首帧就有内容，随后静默把在线数据换上来（滚动位置不动）。
///
/// 三种状态：
/// * **有本机副本** → 立即交给 [builder]（`fresh = false`）→ 后台 [YmLocalFirstAsync.loadRemote]；
///   成功：原地换数据（`fresh = true`）；失败：[onRefreshFailed]（页面弹「数据更新失败」、
///   副行标「离线」），但内容留着，不退回空白；
/// * **没有副本** → 正常 loading → 失败出「加载失败 + 重试」/「登录后使用」（与 YmAsync 同文案）。
///
/// ⚠ `fresh = false` 这一小段时间里，**服务端写操作（收藏）不许放行**：副本里的
/// CSRF 令牌可能是旧的，用户点了会得到「登录失效」。页面拿 `fresh` 去锁按钮。
class YmLocalFirstAsync<T> extends StatefulWidget {
  const YmLocalFirstAsync({
    super.key,
    required this.loadLocal,
    required this.loadRemote,
    required this.builder,
    this.errorTitle = '加载失败',
    this.onLogin,
    this.loginDesc,
    this.onRefreshFailed,
    this.onRefreshDone,
  });

  /// 本机那份；`null` = 没有副本（走正常网络加载）。
  final Future<T?> Function() loadLocal;

  /// 取在线版本。`force` = 手动刷新，要绕过进程内缓存。
  final Future<T> Function({bool force}) loadRemote;

  /// `fresh` = 眼前这份数据来自网络（false = 本机副本 / 刷新失败）。
  final Widget Function(BuildContext context, T data, bool fresh) builder;

  final String errorTitle;
  final VoidCallback? onLogin;
  final String? loginDesc;

  /// 后台刷新失败（自动进页面 / 菜单里手动刷新，都走这里）。
  final VoidCallback? onRefreshFailed;

  /// 刷新**成功**、数据已经换成在线版本（自动进页面 / 手动刷新都走这里）。
  ///
  /// 与 [onRefreshFailed] 对称：失败一句「数据更新失败」，成功一句「数据更新成功」。
  /// 首屏网络加载（`_firstLoad`）不走这里 —— 那是 loading 之后的正常出内容，不是「更新」。
  final VoidCallback? onRefreshDone;

  @override
  State<YmLocalFirstAsync<T>> createState() => YmLocalFirstAsyncState<T>();
}

class YmLocalFirstAsyncState<T> extends State<YmLocalFirstAsync<T>> {
  T? _data;
  Object? _error;
  bool _loading = false;
  bool _fresh = false;
  bool _refreshing = false;

  /// 登录态变化要自动重取（与 YmAsync 同一口径：登录回来页面才会出内容）。
  bool _wasLoggedIn = YmSession.loggedIn;

  @override
  void initState() {
    super.initState();
    YmSession.account.addListener(_onAccount);
    unawaited(_boot());
  }

  @override
  void dispose() {
    YmSession.account.removeListener(_onAccount);
    super.dispose();
  }

  void _onAccount() {
    final now = YmSession.loggedIn;
    if (now == _wasLoggedIn) return;
    _wasLoggedIn = now;
    if (now && mounted) unawaited(refresh(force: true));
  }

  Future<void> _boot() async {
    T? local;
    try {
      local = await widget.loadLocal();
    } catch (_) {
      local = null; // 副本读坏了就当没有，别把页面卡在错误态
    }
    if (!mounted) return;
    if (local != null) {
      setState(() {
        _data = local;
        _fresh = false;
        _loading = false;
      });
      // **有本机副本时必须真取一次网络**（`force: true`）：不 force 的话
      // `fetchDetail` 命中五分钟进程内缓存、根本不发请求，断网也会「刷新成功」
      // 并弹「数据更新成功」——那只是内存里的旧数据（2026-11-24 真机反馈）。
      // 没有副本时走 `_firstLoad`，照旧吃缓存。
      await refresh(force: true);
      return;
    }
    await _firstLoad();
  }

  Future<void> _firstLoad() async {
    setState(() => _loading = true);
    try {
      final data = await widget.loadRemote(force: false);
      if (!mounted) return;
      setState(() {
        _data = data;
        _fresh = true;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  /// 刷新：自动（进页面后）与手动（右上角菜单）共用。
  ///
  /// 返回 `true` = 换成了在线版本（已回调 [YmLocalFirstAsync.onRefreshDone]）；
  /// `false` = 失败（已回调 [YmLocalFirstAsync.onRefreshFailed]，眼前内容保持不动）。
  Future<bool> refresh({bool force = false}) async {
    if (_refreshing) return false;
    setState(() => _refreshing = true);
    try {
      final data = await widget.loadRemote(force: force);
      if (!mounted) return false;
      setState(() {
        _data = data;
        _fresh = true;
        _error = null;
      });
      widget.onRefreshDone?.call();
      return true;
    } catch (_) {
      if (!mounted) return false;
      widget.onRefreshFailed?.call();
      return false;
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    Widget content;
    if (data != null) {
      content = widget.builder(context, data, _fresh);
    } else if (_loading) {
      content = const YmLoadingView();
    } else {
      final err = _error;
      final login = err is YmHttpError && err.isLoginRequired;
      final body = login
          ? YmLoginRequired(
              // ⚠ 必须 true：下面已经把它包进 ListView 了（同 YmAsync 的注释）
              embedded: true,
              onLogin: widget.onLogin,
              desc: widget.loginDesc,
            )
          : YmStateView(
              title: widget.errorTitle,
              desc: err is YmHttpError ? err.message : '请检查网络后重试',
              actionLabel: '重试',
              // 首屏失败的重试不弹「数据更新失败」：错误页自己已经说清楚了
              onAction: () => unawaited(_firstLoad()),
            );
      content = ListView(padding: const EdgeInsets.only(bottom: 8), children: [body]);
    }
    // 正在真取一次网络（自动进页面 / 菜单手动刷新）⇒ 顶栏下沿占 2px 的一根条，
    // 与内置网页壳同构；刷新一结束就撤掉，成功 / 失败仍由 toast 与副行表达。
    // 首屏加载不出条：那时有骨架屏与「正在加载…」，不叠第二个指示（2026-11-24 用户定）。
    if (!_refreshing) return content;
    return Column(
      children: <Widget>[
        const YmLoadBar(),
        Expanded(child: content),
      ],
    );
  }
}
