import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/app.dart';
import 'package:yamibo_flutter/data/api.dart';
import 'package:yamibo_flutter/data/app_state.dart';
import 'package:yamibo_flutter/data/http.dart';

/// 文本框长按菜单是 Material 内置文案：没配本地化就显示英文 Copy / Paste。
/// 应用固定简体中文（SDK 自带的 flutter_localizations）。
void main() {
  setUp(() {
    clearCache();
    rootTab.value = 0;
    // 首页等页面会取站点数据：本用例只关心本地化，统一按「需要登录」收束。
    YmHttp.debugHandler = (path) async =>
        throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
  });

  tearDown(() {
    YmHttp.debugHandler = null;
    clearCache();
  });

  testWidgets('应用把 Material 内置文案配成中文（复制 / 剪切 / 粘贴 / 全选）',
      (tester) async {
    await tester.pumpWidget(const YamiboApp());
    await tester.pumpAndSettle();

    final l10n = MaterialLocalizations.of(
      tester.element(find.byType(RootShell)),
    );
    expect(l10n.copyButtonLabel, '复制');
    expect(l10n.cutButtonLabel, '剪切');
    expect(l10n.pasteButtonLabel, '粘贴');
    expect(l10n.selectAllButtonLabel, '全选');
  });
}