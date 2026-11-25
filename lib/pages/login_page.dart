import 'package:flutter/material.dart';

import '../data/auth.dart';
import '../data/forum/forum_auth.dart';
import '../data/session.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/button.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/rows.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/top_bar.dart';
import '../design/ym_route.dart';
import 'login_web_page.dart';

/// 账号页。版式对齐 uni `pages/login/login.vue`：
/// summary 卡（昵称 / UID / 一个主按钮）+（已登录时）「退出登录」行 + 状态提示。
///
/// 登录本身在站内网页里完成（[LoginWebPage]），本页只展示结论与提供刷新/退出。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _message;

  Future<void> _openLogin() async {
    final ok =
        await Navigator.of(context).push<bool>(ymRoute(const LoginWebPage(), snapshot: false));
    if (!mounted) return;
    setState(() {
      // 中途返回：可能已登进去（返回键也会同步 Cookie），也可能放弃了
      _message = (ok == true || YmSession.loggedIn) ? null : '还没有完成登录。';
    });
  }

  /// 回站核对一次（顺带从 WebView 同步最新 Cookie）。
  Future<void> _recheck() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final acc = await YmAuth.checkLogin();
      if (!mounted) return;
      setState(() {
        _message = acc.loggedIn ? null : '站点返回未登录，请重新登录。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '登录状态没能确认，请稍后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    final ok = await showYmConfirm(
      context,
      title: '退出登录',
      content: '确认退出登录吗？',
      confirmText: '退出',
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final remote = await YmAuth.logout();
      if (!mounted) return;
      // 「两份登录态，退出一起清」（拍板口径）：阅读侧退出连带清论坛罐 +
      // 落盘文件；WebView 里 bbs 域的 Cookie 已被 YmAuth.logout 的
      // clearWebviewCookies 按 .yamibo.com 域一起清掉，这里不用重复。
      await ForumSession.clear();
      if (!mounted) return;
      setState(() => _message = remote ? '已退出登录。' : '本机已退出；站点未确认注销。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<YmAccount>(
        valueListenable: YmSession.account,
        builder: (context, acc, _) {
          final c = YmScope.of(context).colors;
          return Column(
            children: [
              const YmTopBar(
                leading: YmBackButton(),
                title: '账号',
                subtitle: '百合会账号',
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Container(
                      margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 0),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(YmRadius.box),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            acc.displayName,
                            style: TextStyle(
                              fontSize: YmFont.strong17,
                              fontWeight: FontWeight.w800,
                              height: 1.35,
                              color: c.text,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            acc.loggedIn
                                ? (acc.uid.isNotEmpty ? 'UID ${acc.uid}' : '已登录')
                                : '登录后可使用搜索与排行',
                            style: TextStyle(
                              fontSize: YmFont.small12,
                              height: 1.6,
                              color: c.text2,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: YmButton(
                                  kind: YmButtonKind.primary,
                                  label: acc.loggedIn
                                      ? (_busy ? '检查中…' : '刷新登录状态')
                                      : '登录',
                                  expanded: true,
                                  onTap: _busy
                                      ? null
                                      : (acc.loggedIn ? _recheck : _openLogin),
                                ),
                              ),
                            ],
                          ),
                          if (!acc.loggedIn) ...[
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: YmButton(
                                    label: _busy ? '检查中…' : '刷新登录状态',
                                    kind: YmButtonKind.tint,
                                    expanded: true,
                                    onTap: _busy ? null : _recheck,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                        child: Text(
                          _message!,
                          style: TextStyle(
                            fontSize: YmFont.small12,
                            height: 1.6,
                            color: c.text2,
                          ),
                        ),
                      ),
                    if (acc.loggedIn) ...[
                      const SizedBox(height: 14),
                      YmCardList(
                        children: [
                          YmActionRow(
                            title: '退出登录',
                            onTap: _busy ? null : _logout,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
