import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/app_state.dart';
import 'data/theme_prefs.dart';
import 'design/theme.dart';
import 'design/tokens.dart';
import 'design/widgets/bottom_nav.dart';
import 'pages/forum/forum_home_page.dart';
import 'pages/home_page.dart';
import 'pages/mine_page.dart';
import 'pages/search_page.dart';
import 'pages/shelf_page.dart';

class YamiboApp extends StatefulWidget {
  const YamiboApp({super.key});

  @override
  State<YamiboApp> createState() => _YamiboAppState();
}

class _YamiboAppState extends State<YamiboApp> {
  /// 配色挂在 [YmThemePrefs] 上：切换时它广播、启动时它先从盘里读回来。
  final YmThemePrefs _prefs = YmThemePrefs.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _prefs,
      builder: (context, _) {
        final themeId = _prefs.themeId;
        return MaterialApp(
          title: '百合会Flutter',
          debugShowCheckedModeBanner: false,
          // 文本框长按菜单（复制 / 粘贴 / 全选）等 Material 内置文案走中文。
          // 之前没配本地化，一直显示英文 Copy / Paste（2026-11-25 用户反馈）。
          locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
          supportedLocales: const [
            Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
          ],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: buildYmTheme(ymPalette(themeId, Brightness.light), Brightness.light),
          darkTheme: buildYmTheme(ymPalette(themeId, Brightness.dark), Brightness.dark),
          themeMode: ThemeMode.system,
          builder: (context, child) {
            final brightness = Theme.of(context).brightness;
            final colors = ymPalette(themeId, brightness);
            final iconBrightness =
                brightness == Brightness.dark ? Brightness.light : Brightness.dark;

            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: iconBrightness,
                statusBarBrightness: brightness,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarDividerColor: Colors.transparent,
                systemNavigationBarIconBrightness: iconBrightness,
                systemNavigationBarContrastEnforced: false,
              ),
              child: YmScope(
                colors: colors,
                themeId: themeId,
                onThemeChanged: _prefs.setThemeId,
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: const RootShell(),
        );
      },
    );
  }
}

/// 五个 tab 用 IndexedStack 保活；切换不销毁页面、不丢滚动位置。
class RootShell extends StatelessWidget {
  const RootShell({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: rootTab,
      builder: (context, index, _) {
        return Scaffold(
          // 版心 780（资产包 SlateScaffold.pageMax）：四个 tab 共用。
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: YmLayout.pageMax),
              child: SizedBox.expand(
                child: IndexedStack(
                  index: index,
                  children: const [
                    HomePage(),
                    SearchPage(),
                    ShelfPage(),
                    ForumHomePage(),
                    MinePage(),
                  ],
                ),
              ),
            ),
          ),
          bottomNavigationBar: YmBottomNav(
            index: index,
            onChanged: (i) => rootTab.value = i,
          ),
        );
      },
    );
  }
}
