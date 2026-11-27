import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:yamibo_flutter/design/app_version.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';
import 'package:yamibo_flutter/pages/about_page.dart';

/// 关于页的**版本契约**（0.1.41 起本文件只剩这两条）：
///
/// 1. 版本号来自安装包（PackageInfo mock → UI 读回），写死的版本串必须彻底消失；
/// 2. 测试假值与 `pubspec.yaml` 的 `version:` 成对——漏改一处就红，升版时
///    两处一起改。
///
/// 许可页面的静态文案（条目文字、全文弹层）不在这里断言：文案改动装到机器上
/// 肉眼过一遍即可。文件名保持 `about_license_test.dart`——它和上面那条「版本
/// 成对」的契约绑在一起，改名会让引用它的地方对不上。

/// 假版本：必须与 `pubspec.yaml` 的 `version:` 同步（第二条测试看守）。
const String _fakeVersion = '0.1.56';
const String _fakeBuild = '2081';

Widget _harness() {
  final colors = YmColors.yamiboLight;
  return MaterialApp(
    theme: buildYmTheme(colors, Brightness.light),
    builder: (context, child) => YmScope(
      colors: colors,
      themeId: YmThemeId.yamibo,
      onThemeChanged: (_) {},
      child: child ?? const SizedBox.shrink(),
    ),
    home: const AboutPage(),
  );
}

void main() {
  // 版本号不再写死在代码里：读的是安装包的 versionName / versionCode。
  // 纯 Dart 测试没有平台通道，不 mock 会抛异常 —— 这是本方案唯一的额外成本。
  testWidgets('关于页显示安装包的版本号 v版本 (构建号)', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: '百合会Flutter',
      packageName: 'com.azusakano.yamibo_flutter',
      version: _fakeVersion,
      buildNumber: _fakeBuild,
      buildSignature: '',
    );
    YmAppVersion.debugReset();

    await tester.pumpWidget(_harness());
    // 首帧时还没读到，整行不显示（不闪 v0.0.0）。
    expect(find.text('v$_fakeVersion ($_fakeBuild)'), findsNothing);
    // 读回来之后自己刷新。
    await tester.pump();
    await tester.pump();

    expect(find.text('v$_fakeVersion ($_fakeBuild)'), findsOneWidget);
    // 老的写死串必须彻底消失。
    expect(find.text('v0.1.1'), findsNothing);
  });

  // 守的是「版本只有一个来源」这条产品契约：假值若忘了跟 pubspec 同步，这里就红。
  // ⚠ 只证明「测试假值 vs 清单」一致，不证明运行时读得对（那靠真机 dumpsys 核对）。
  test('mock 版本与 pubspec.yaml 的 version 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final matched =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);

    expect(matched, isNotNull, reason: 'pubspec.yaml 里找不到 version: 行');
    expect(matched!.group(1), '$_fakeVersion+$_fakeBuild');
  });
}
