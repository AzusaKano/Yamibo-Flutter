import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/session.dart';

/// 会话层的纯逻辑回归（不发网络、不落盘：测试环境没有 `ym/native` 通道，
/// `save()` 会静默降级，正好顺带验一次降级不抛）。
void main() {
  setUp(YmSession.resetForTest);
  tearDown(YmSession.resetForTest);

  test('Cookie 罐：收 Set-Cookie、拼头、替换、清空属性', () {
    YmSession.absorbSetCookie(<String>['a=1; Path=/', 'b=2; HttpOnly; Path=/']);
    expect(YmSession.cookieHeader(), 'a=1; b=2');

    // 站点换过会话：以 WebView 里那份为准（先清空）
    YmSession.absorbCookieHeader('c=3; a=9', replace: true);
    expect(YmSession.cookieHeader(), 'c=3; a=9');

    // 过期写空值 = 删除该键
    YmSession.absorbSetCookie(<String>['a=; Max-Age=0']);
    expect(YmSession.cookieHeader(), 'c=3');
  });

  test('账号视图：登录 / 未登录 / 清空 都会通知', () async {
    YmSession.absorbCookieHeader('PHPSESSID=abc; _csrf-frontend=t');
    var notified = 0;
    void listener() => notified += 1;
    YmSession.account.addListener(listener);
    addTearDown(() => YmSession.account.removeListener(listener));

    await YmSession.apply(const YmAccount(
      loggedIn: true,
      name: '测试',
      uid: '585764',
      checkedAt: 1,
    ));
    expect(YmSession.loggedIn, isTrue);
    expect(YmSession.account.value.displayName, '测试');
    expect(notified, 1);

    // `/my` 判定未登录：只退视图，Cookie 还在（站点刚给的那份还有用）
    await YmSession.markLoggedOut();
    expect(YmSession.loggedIn, isFalse);
    expect(YmSession.cookieHeader(), contains('PHPSESSID=abc'));
    expect(notified, 2);

    // 已经是游客再 clear：值没变就不该多刷一次界面（ValueNotifier 按值判等）
    await YmSession.clear();
    expect(YmSession.cookieHeader(), isNull);
    expect(notified, 2);

    // 登录状态下退出：账号视图确实变了，要通知
    await YmSession.apply(const YmAccount(loggedIn: true, name: '测试'));
    expect(notified, 3);
    await YmSession.clear();
    expect(notified, 4);
  });

  test('没有昵称但确实已登录时，显示名退回「已登录」', () async {
    await YmSession.apply(const YmAccount(loggedIn: true));
    expect(YmSession.account.value.displayName, '已登录');
  });
}
