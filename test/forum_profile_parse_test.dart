// 资料页解析（**公开**：手写最小 HTML，不读 test/fixtures）。
//
// 钉住三件最容易写反的事：
//   ① 三格是「值在标签前」、资料行是「值在标签后」，两套解析不能合并；
//   ② 签名是 `li.sig`（不是 div.sig），`<br>` 转换行；
//   ③ `-` / 空 span / 裸 `http://` 一律归 null 且整行不出现。
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/forum/forum_parser.dart';
import 'package:yamibo_flutter/data/http.dart' show YmHttpError;

/// 他人视角：三格齐全 + 资料行齐全 + 签名单独一块。
/// [total] 换掉「总积分」那一格的值（`null` = 这一格不印）。
String otherPage({String? total = '12345', String sig = ''}) {
  final stats = <String>[
    if (total != null) '<li><span>$total</span>总积分</li>',
    '<li><span>12000 点</span>积分</li>',
    '<li><span>300</span>对象</li>',
  ].join();
  return '''
<html><body>
<div class="userinfo">
<div class="user_avatar"><div class="avatar_bg">
<div class="avatar_m"><img src="/uc_server/data/avatar/000/11/11/11_avatar_middle.jpg"></div>
<h2 class="name">甲用户</h2>
</div></div>
<div class="user_box cl"><ul>$stats</ul></div>
<div class="myinfo_list cl"><ul>
<li><b>个人签名</b></li>
<li class="sig">$sig</li>
</ul></div>
<div class="myinfo_list cl"><ul>
<li><b>个人资料</b><span class="mtxt"><a href="/home.php?mod=spacecp">设置</a></span></li>
<li>UID<span>111111</span></li>
<li>用户组<span style="color:#9932cc"><font color="#9932cc">粮仓组</font></span></li>
<li>管理组<span style="color:"></span></li><li>个人主页<span>http://</span></li>
<li>性别<span>保密</span></li>
<li>生日<span>-</span></li>
<li>星座<span>摩羯座</span></li>
<li>毕业学校<span>某院校</span></li>
<li>自定义头衔<span>测试头衔</span></li>
<li>在线时间<span>9358 小时</span></li><li>注册时间<span>2023-1-1 10:00</span></li>
<li>最后访问<span>2026-1-1 10:00</span></li>
</ul></div>
</div>
</body></html>
''';
}

void main() {
  test('三格：值在标签前，积分去「点」', () {
    final p = parseUserProfile(otherPage(), uid: '111111');
    expect(p.totalPoints, 12345);
    expect(p.points, 12000);
    expect(p.partner, 300);
  });

  test('资料行：值在标签后（写反了就是标签当值）', () {
    final p = parseUserProfile(otherPage(), uid: '111111');
    expect(p.uid, '111111');
    // 值 / 标签没有互换：标签里绝不能出现数字，值里不能出现「UID」这类标签词
    for (final f in p.fields) {
      expect(RegExp(r'^\d+$').hasMatch(f.label), isFalse, reason: f.label);
      expect(f.value, isNot('UID'));
    }
    expect(
      p.fields.firstWhere((f) => f.label == 'UID').value,
      '111111',
    );
  });

  test('用户组剥掉 <font>，管理组空 span 不进 fields', () {
    final p = parseUserProfile(otherPage());
    expect(p.group, '粮仓组');
    expect(p.adminGroup, isEmpty);
    expect(p.fields.any((f) => f.label == '管理组'), isFalse);
  });

  test('`-` / 空串 / 裸 http:// 归 null，且整行不出现', () {
    final p = parseUserProfile(otherPage());
    expect(p.fields.any((f) => f.label == '生日'), isFalse);
    expect(p.fields.any((f) => f.label == '个人主页'), isFalse);
    expect(p.fields.any((f) => f.value == '-' || f.value.isEmpty), isFalse);
  });

  test('在线时间只留数字，资料表里仍印站点原文', () {
    final p = parseUserProfile(otherPage());
    expect(p.onlineHours, 9358);
    expect(
      p.fields.firstWhere((f) => f.label == '在线时间').value,
      '9358 小时',
    );
  });

  test('签名：li.sig，<br> 转换行', () {
    final p = parseUserProfile(
      otherPage(sig: '第一行<br><a href="https://example.com/">一个链接</a><br>第三行'),
    );
    expect(p.signature, '第一行\n一个链接\n第三行');
  });

  test('三格「0」是有意义的 0，不是「站点没印」', () {
    final p = parseUserProfile(otherPage(total: '0'));
    expect(p.totalPoints, 0);
  });

  test('三格缺一格就是 null（页面据此不画那一格）', () {
    final p = parseUserProfile(otherPage(total: null));
    expect(p.totalPoints, isNull);
    expect(p.points, 12000);
  });

  test('isSelf：有 btn_exit', () {
    final p = parseUserProfile('${otherPage()}<div class="btn_exit"><a>退出登录</a></div>');
    expect(p.isSelf, isTrue);
  });

  test('isSelf：资料表头带「设置」', () {
    // otherPage 的头版就带「设置」链接，等同于自己视角
    expect(parseUserProfile(otherPage()).isSelf, isTrue);
  });

  test('isSelf：两者都没有就是他人视角', () {
    final html = otherPage().replaceFirst(
      '<li><b>个人资料</b><span class="mtxt"><a href="/home.php?mod=spacecp">设置</a></span></li>',
      '<li><b>个人资料</b></li>',
    );
    final p = parseUserProfile(html);
    expect(p.isSelf, isFalse);
    // 表头行不能变成一条「个人资料: 设置」的资料行
    expect(p.fields.any((f) => f.label == '个人资料'), isFalse);
  });

  test('最后访问归头卡，资料表里不重复', () {
    final p = parseUserProfile(otherPage());
    expect(p.lastVisit, '2026-1-1 10:00');
    expect(p.fields.any((f) => f.label == '最后访问'), isFalse);
  });

  test('名字与资料行都取不到 → PARSE（交给上层翻人话）', () {
    expect(
      () => parseUserProfile('<html><body><div class="jump_c"><p>用户空间不存在</p></div></body></html>'),
      throwsA(isA<YmHttpError>().having((e) => e.code, 'code', 'PARSE')),
    );
  });

  test('只有名字、没有资料行：照常返回，不抛', () {
    final p = parseUserProfile('<html><body><h2 class="name">甲用户</h2></body></html>');
    expect(p.name, '甲用户');
    expect(p.fields, isEmpty);
  });
}
