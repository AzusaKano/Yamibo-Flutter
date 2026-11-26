// 资料页界面（**公开**：手写最小 HTML 桩，不读 test/fixtures）。
//
// 钉住口径：五态各自可见、缺一格不画那一格、主题首屏 10 条、
// 楼层卡作者行可点且 uid 为空时不可点。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/forum/forum_http.dart';
import 'package:yamibo_flutter/data/forum/forum_models.dart';
import 'package:yamibo_flutter/data/http.dart' show YmHttpError;
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/forum/forum_post_card.dart';
import 'package:yamibo_flutter/design/widgets/forum/forum_profile_head.dart';
import 'package:yamibo_flutter/design/widgets/forum/forum_thread_row.dart';
import 'package:yamibo_flutter/pages/forum/forum_profile_page.dart';

/// 资料页样本（他人视角）。[total] / [partner] 传 null = 站点没印那一格。
String profileHtml({
  String? total = '12345',
  String? partner = '300',
  bool self = false,
  String signature = '第一行签名<br>第二行签名',
}) {
  final stats = <String>[
    if (total != null) '<li><span>$total</span>总积分</li>',
    '<li><span>12000 点</span>积分</li>',
    if (partner != null) '<li><span>$partner</span>对象</li>',
  ].join();
  return '''
<html><body>
<div class="userinfo">
<h2 class="name">${self ? '乙用户' : '甲用户'}</h2>
<div class="user_box cl"><ul>$stats</ul></div>
${signature.isEmpty ? '' : '<div class="myinfo_list cl"><ul><li><b>个人签名</b></li><li class="sig">$signature</li></ul></div>'}
<div class="myinfo_list cl"><ul>
<li><b>个人资料</b></li>
<li>UID<span>111111</span></li>
<li>用户组<span style="color:#9932cc"><font color="#9932cc">粮仓组</font></span></li>
<li>性别<span>保密</span></li>
<li>生日<span>-</span></li>
<li>星座<span>摩羯座</span></li>
<li>出生地<span>某市</span></li>
<li>毕业学校<span>某院校</span></li>
<li>自定义头衔<span>测试头衔</span></li>
<li>QQ<span>10001</span></li>
<li>个人主页<span>https://example.com/</span></li>
<li>在线时间<span>9358 小时</span></li>
<li>注册时间<span>2023-1-1 10:00</span></li>
<li>最后访问<span>2026-1-1 10:00</span></li>
</ul></div>
</div>
${self ? '<div class="btn_exit"><a href="/member.php?mod=logging&amp;action=logout&amp;formhash=deadbeef">退出登录</a></div>' : ''}
</body></html>
''';
}

/// TA 的主题列表（行结构与板块页同构）。
String threadsHtml(int count) {
  final rows = List.generate(count, (i) => '''
<li class="list">
<div class="threadlist_top cl">
<a href="/home.php?mod=space&amp;uid=111111&amp;mobile=2" class="mimg"><img src="/a.jpg"></a>
<div class="muser"><h3><a href="/home.php?mod=space&amp;uid=111111&amp;mobile=2" class="mmc">甲用户</a></h3>
<span class="mtime">2024-1-1</span></div>
</div>
<a href="/forum.php?mod=viewthread&amp;tid=${203400 + i}&amp;mobile=2">
<div class="threadlist_tit cl"><em>主题 $i</em></div>
</a>
<div class="threadlist_foot cl"><ul>
<li class="mr"><a href="/forum.php?mod=forumdisplay&amp;fid=55&amp;mobile=2">#测试板块</a></li>
<li><i class="dm-eye-fill"></i>${100 + i}</li>
<li><i class="dm-chat-s-fill"></i>$i</li>
</ul></div>
</li>''').join();
  return '<html><body><div class="threadlist cl"><ul>$rows</ul></div></body></html>';
}

void main() {
  tearDown(() => ForumHttp.debugHandler = null);

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1080, 9000);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  void stub({
    String? profile,
    int threads = 0,
    Object? profileError,
    Object? threadsError,
  }) {
    ForumHttp.debugHandler = (url) async {
      if (url.contains('do=thread')) {
        if (threadsError != null) throw threadsError;
        return ForumRawResponse(status: 200, body: threadsHtml(threads));
      }
      if (profileError != null) throw profileError;
      return ForumRawResponse(status: 200, body: profile ?? profileHtml());
    };
  }

  // ⚠ 每个用例换一个 uid：资料页有**进程内缓存**（上限 12 条，是刻意的口径），
  // 同一个 uid 会直接命中上一轮的结果，错误态就测不出来了。
  testWidgets('正常态：头卡 + 三格 + 资料表 + 主题首屏 10 条', (tester) async {
    stub(threads: 12);
    await pump(tester, const ForumProfilePage(uid: '111111'));

    // 头卡里的名字（列表行里也有同名文字，圈进头卡才准）
    expect(
      find.descendant(
        of: find.byType(YmForumProfileHead),
        matching: find.text('甲用户'),
      ),
      findsOneWidget,
    );
    expect(find.text('粮仓组'), findsOneWidget);
    expect(find.text('最后访问 2026-1-1 10:00'), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
    expect(find.text('12000'), findsOneWidget); // 积分原文带「点」，只显示数字
    expect(find.text('总积分'), findsOneWidget);
    expect(find.text('对象'), findsOneWidget);
    // 资料表：默认只铺 8 行（本样本 10 行），第 9 行起折起来
    expect(find.text('性别'), findsOneWidget);
    expect(find.text('QQ'), findsOneWidget);
    expect(find.text('注册时间'), findsNothing);
    expect(find.textContaining('展开全部'), findsOneWidget);
    // 签名卡
    expect(find.text('个人签名'), findsOneWidget);
    // 主题首屏上限 10 条：12 条里只铺 10 条
    expect(find.text('TA 的主题'), findsOneWidget);
    expect(find.byType(YmForumThreadRow), findsNWidgets(10));
    expect(find.text('主题 10'), findsNothing);
  });

  testWidgets('缺格不画：站点没印总积分就不出现「总积分」', (tester) async {
    stub(profile: profileHtml(total: null), threads: 1);
    await pump(tester, const ForumProfilePage(uid: '222222'));

    expect(find.text('总积分'), findsNothing);
    expect(find.text('积分'), findsOneWidget);
    expect(find.text('对象'), findsOneWidget);
  });

  testWidgets('主题拿不到：资料照常显示，主题区安静不画', (tester) async {
    stub(
      threadsError: YmHttpError('站点返回 500', code: 'HTTP'),
    );
    await pump(tester, const ForumProfilePage(uid: '333333'));

    expect(find.text('甲用户'), findsWidgets); // 头卡 + 无列表行也在
    expect(find.text('TA 的主题'), findsNothing);
    expect(find.text('资料加载失败'), findsNothing);
  });

  testWidgets('未登录：整屏「登录后使用」+ 去登录', (tester) async {
    stub(profileError: YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED'));
    await pump(tester, const ForumProfilePage(uid: '444444'));

    expect(find.text('登录后使用'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    expect(find.text('甲用户'), findsNothing);
  });

  testWidgets('WAF：只出「去验证」，不出「重试」', (tester) async {
    stub(profileError: YmHttpError('论坛正在安全验证，请稍后再试', code: 'WAF'));
    await pump(tester, const ForumProfilePage(uid: '555555'));

    expect(find.text('去验证'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('空间不存在：中性标题 + 站点原文，不挂按钮', (tester) async {
    stub(profileError: YmHttpError('用户空间不存在', code: 'SITE_MESSAGE'));
    await pump(tester, const ForumProfilePage(uid: '999999'));

    expect(find.text('论坛暂时无法访问'), findsOneWidget);
    expect(find.text('用户空间不存在'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('解析不出：资料加载失败 + 重试', (tester) async {
    stub(profileError: YmHttpError('没能认出资料页', code: 'PARSE'));
    await pump(tester, const ForumProfilePage(uid: '777777'));

    expect(find.text('资料加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('楼层卡作者行：有 uid 可点，无 uid 不可点', (tester) async {
    var taps = 0;
    ForumPost post(String uid) => ForumPost(
      pid: '1',
      floor: 1,
      author: '甲用户',
      authorUid: uid,
      time: '2026-1-1',
    );

    await pump(
      tester,
      Scaffold(
        body: YmForumPostCard(
          post: post('111111'),
          isOp: true,
          commentsExpanded: false,
          onToggleComments: () {},
          onReply: (_) {},
          onTapAuthor: () => taps++,
        ),
      ),
    );
    await tester.tap(find.text('甲用户'));
    await tester.pump();
    expect(taps, 1);

    taps = 0;
    await pump(
      tester,
      Scaffold(
        body: YmForumPostCard(
          post: post(''),
          isOp: true,
          commentsExpanded: false,
          onToggleComments: () {},
          onReply: (_) {},
          onTapAuthor: null,
        ),
      ),
    );
    await tester.tap(find.text('甲用户'));
    await tester.pump();
    expect(taps, 0);
  });
}
