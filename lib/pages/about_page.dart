import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../data/forum/forum_http.dart' show ForumHttp;
import '../design/app_version.dart';
import '../design/licenses/gpl3.dart';
import '../design/pressable.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/rows.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/toast.dart';
import '../design/widgets/top_bar.dart';
import '../dev/metrics.dart';
import 'gallery_page.dart';
import 'routes.dart';

/// 关于。版式对齐 uni `pages/about/about.vue`：品牌图 + 名称 + 版本，
/// 中间一张版权声明卡，**底部署名钉在屏底**（内容短也不往上跑）。
///
/// 版本号取自安装包（`YmAppVersion`，读 versionName/versionCode），不写死；
/// 升版本只改 `pubspec.yaml`。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    // 版本号异步读（幂等，只读一次），不阻塞首帧；读到后由下面的
    // ValueListenableBuilder 自己刷新。
    YmAppVersion.ensureLoaded();
    return Scaffold(
      body: Column(
        children: [
          const YmTopBar(leading: YmBackButton(), title: '关于'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                const SizedBox(height: 24),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(YmRadius.box),
                    child: Image.asset(
                      'assets/icon/app-icon-1024.png',
                      width: 84,
                      height: 84,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '百合会Flutter',
                  textAlign: TextAlign.center,
                  // ⚠ 例外（书面）：应用名是页头展示标题，16/800 是资产包已声明的组合
                  //（`.saved-route{16px/800/1.35}`，saved_route_card.dart），
                  // strong16 默认 700 属「卡内标题」档，本处高一级。
                  style: TextStyle(
                    fontSize: YmFont.strong16,
                    fontWeight: FontWeight.w800,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 4),
                // 版本号取自安装包。还没读到时整行不占位（不闪 v0.0.0）；
                // 样式与位置不动，只换内容。
                ValueListenableBuilder<String>(
                  valueListenable: YmAppVersion.label,
                  builder: (context, version, _) {
                    if (version.isEmpty) return const SizedBox.shrink();
                    return Text(
                      version,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: YmFont.small12, color: c.text2),
                    );
                  },
                ),
                const SizedBox(height: 24),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: YmLayout.pagePad),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: BorderRadius.circular(YmRadius.box),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _line(c, '本应用为百合会（yamibo.com）的非官方阅读客户端。'),
                      const SizedBox(height: 8),
                      _line(c, '作品、封面与章节内容的一切权利归原作者与论坛所有。'),
                      const SizedBox(height: 8),
                      // 本应用自身的许可：点开看 GPL 全文。用强调色表示可点，
                      // 不再另起一行提示文字。
                      Align(
                        alignment: Alignment.centerLeft,
                        child: YmPressable(
                          kind: YmPressKind.dim,
                          onTap: () => _showLicense(context, _selfLicense),
                          child: Text(
                            '本应用以 GNU General Public License v3.0 授权。',
                            style: TextStyle(
                              fontSize: YmFont.small12,
                              height: 1.7,
                              color: c.accentInk,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 开源许可：像通常 App 的第三方声明一样**逐项列出**（项目名 +
                // 版权 + 许可证），点行看各自全文。清单 = 设计系统 + Flutter
                // 框架与三个直接依赖（间接依赖不列，保持一页可扫）。全文逐字
                // 取自各项目随附的 LICENSE（pub 缓存 / Flutter SDK 实抓，
                // 2026-11-22），不转写不改写——BSD / MIT 二进制分发须随附原文。
                const SizedBox(height: 14),
                const YmSectionHeader(
                  title: '开源许可',
                  padding: EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10),
                  child: _line(c, '本应用基于以下开源项目构建。'),
                ),
                YmCardList(
                  children: [
                    for (final p in _ossProjects)
                      YmActionRow(
                        title: p.name,
                        value: '${p.copyright} · ${p.license}',
                        onTap: () => _showLicense(context, p),
                      ),
                  ],
                ),
                // 开发自用：指标与控件样板从「我的」移到这里（2026-11-09 拍板）。
                const SizedBox(height: 14),
                const YmSectionHeader(
                  title: '开发指标',
                  padding: EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: YmLayout.pagePad),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: BorderRadius.circular(YmRadius.box),
                  ),
                  child: AnimatedBuilder(
                    animation: Listenable.merge([ymMetrics, ymFrameStats]),
                    builder: (context, _) {
                      final press = ymMetrics['press'];
                      final tab = ymMetrics['tab'];
                      final route = ymMetrics['route'];
                      String fmt(YmMetric? m) =>
                          m == null ? '—' : '${m.frames} 帧 · ${m.ms.toStringAsFixed(1)} ms';
                      final build = ymFrameStats.avgBuildMs;
                      final raster = ymFrameStats.avgRasterMs;

                      return Column(
                        children: [
                          _MetricRow(label: '按下反馈', value: fmt(press)),
                          _MetricRow(label: 'Tab 切换', value: fmt(tab)),
                          _MetricRow(label: '路由转场', value: fmt(route)),
                          _MetricRow(
                            label: '近 30 帧耗时',
                            value: build == null || raster == null
                                ? '—'
                                : 'build ${build.toStringAsFixed(1)} / raster ${raster.toStringAsFixed(1)} ms',
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '数值是「输入 → 首个完成构图的帧」。在首页点按、切底栏、进详情后回来看。',
                            style: TextStyle(
                              fontSize: YmFont.micro11,
                              height: 1.5,
                              color: c.text3,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: YmPressable(
                              kind: YmPressKind.row,
                              radius: BorderRadius.circular(YmRadius.chip),
                              onTap: () => ymPush(context, const GalleryPage()),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Text(
                                  '控件样板',
                                  style: TextStyle(
                                    fontSize: YmFont.sub13,
                                    fontWeight: FontWeight.w700,
                                    color: c.brandInk,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 论坛 WAF 排查用：最近 60 条论坛请求的时序（方法/路径/状态/耗时，
                          // 只记元数据）。放这里不放搜索页——它是全论坛的观测口，不是搜索的（2026-11-14 拍板）。
                          const SizedBox(height: 4),
                          Center(
                            child: YmPressable(
                              kind: YmPressKind.row,
                              radius: BorderRadius.circular(YmRadius.chip),
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: ForumHttp.netLogDump()));
                                showYmToast(context, '论坛网络日志已复制');
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Text(
                                  '复制论坛网络日志',
                                  style: TextStyle(
                                    fontSize: YmFont.sub13,
                                    fontWeight: FontWeight.w700,
                                    color: c.brandInk,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          // 署名钉在屏底。设计资产来源已由《轨交速查》整合为 RTGo（2026-11-09）。
          _Credit(c: c),
        ],
      ),
    );
  }

  Widget _line(YmColors c, String text) => Text(
        text,
        style: TextStyle(
          fontSize: YmFont.small12,
          height: 1.7,
          color: c.text2,
        ),
      );
}

/// 底部署名块。占位固定在页面底部、不参与上面的滚动，
/// 内容再长再短它都在最下面；底部内距要自己加系统手势条的高度
/// （Scaffold 的 body 不吃进底部安全区）。
class _Credit extends StatelessWidget {
  const _Credit({required this.c});

  final YmColors c;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(top: 16, bottom: safeBottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Designed by AzusaKano with RTGo',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: YmFont.small12,
              letterSpacing: 0.2,
              color: c.text3,
            ),
          ),
        ],
      ),
    );
  }
}


class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: YmFont.small12, color: c.text2),
            ),
          ),
          Text(
            value,
            // ⚠ 例外（书面）：开发指标的**读数**（右列数值），不是成句的说明文字，
            // 与左侧标签靠「同档不同重 + tabularFigures」对齐读数；资产包无对应类。
            style: TextStyle(
              fontSize: YmFont.small12,
              color: c.text,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 开源组件条目：名称 / 版权行 / 许可证 / 全文。全文**逐字**取自各项目随附的
/// LICENSE（pub 缓存与 Flutter SDK 实抓，2026-11-22），不转写不改写——
/// GPL / BSD / MIT 二进制分发须随附原文。顺序 = 对这个 App 的「引用层级」：
/// 自身许可最先，设计系统其次，框架再次，直接依赖按 pubspec 顺序。
typedef _OssEntry = ({String name, String copyright, String license, String text});

/// 本应用自身的许可。它不属于「基于以下开源项目构建」的清单，
/// 但二进制分发须随附全文（GPL-3.0 §6），所以单独持有、供入口引用。
const _OssEntry _selfLicense = (
  name: 'Yamibo-Flutter',
  copyright: 'Copyright (c) 2026 AzusaKano',
  license: 'GPL-3.0-only',
  text: kGpl3License,
);

const List<_OssEntry> _ossProjects = [
  (
    name: 'rtgo_flutter',
    copyright: 'Copyright (c) 2026 AzusaKano',
    license: 'BSD-3-Clause',
    text: _rtgoLicense,
  ),
  (
    name: 'Flutter',
    copyright: 'Copyright 2014 The Flutter Authors',
    license: 'BSD-3-Clause',
    text: _flutterLicense,
  ),
  (
    name: 'flutter_svg',
    copyright: 'Copyright (c) 2018 Dan Field',
    license: 'MIT',
    text: _flutterSvgLicense,
  ),
  (
    name: 'package_info_plus',
    copyright: 'Copyright 2017 The Chromium Authors',
    license: 'BSD-3-Clause',
    text: _packageInfoLicense,
  ),
  (
    name: 'webview_flutter',
    copyright: 'Copyright 2013 The Flutter Authors',
    license: 'BSD-3-Clause',
    text: _webviewLicense,
  ),
];

/// RTGo 的许可全文（BSD-3-Clause；二进制分发须随附）。不写标题行：弹层标题
/// 已是项目名，且与其他条目「全文直接以版权行开头」的口径一致。
const String _rtgoLicense = '''
Copyright (c) 2026, AzusaKano

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
''';

/// Flutter 框架许可（BSD-3-Clause）。逐字取自 Flutter SDK 根目录 LICENSE 的
/// Flutter Authors 段；引擎 / 字体的第三方条目不在此列（通常 App 的许可页
/// 也只列到框架档，全量随包以 LicensePage 口径为准）。
const String _flutterLicense = '''
Copyright 2014 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
''';

/// flutter_svg 许可全文（MIT；逐字取自 pub 缓存包内 LICENSE）。
const String _flutterSvgLicense = '''
Copyright (c) 2018 Dan Field

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';

/// package_info_plus 许可全文（BSD-3-Clause；逐字取自 pub 缓存包内 LICENSE）。
const String _packageInfoLicense = '''
Copyright 2017 The Chromium Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
''';

/// webview_flutter 许可全文（BSD-3-Clause；逐字取自 pub 缓存包内 LICENSE，
/// 平台实现包 android / wkwebview 同文）。
const String _webviewLicense = '''
Copyright 2013 The Flutter Authors

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
''';

/// 许可全文弹层：一条许可一屏，长文只在这里滚动，关于页保持一屏内可扫。
Future<void> _showLicense(BuildContext context, _OssEntry entry) {
  final c = YmScope.of(context).colors;
  return showYmSheet<void>(
    context,
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          YmSheetHeader(title: entry.name),
          const SizedBox(height: 10),
          Flexible(
            child: SingleChildScrollView(
              child: Text(
                entry.text,
                style: TextStyle(
                  fontSize: YmFont.small12,
                  height: 1.7,
                  color: c.text2,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
