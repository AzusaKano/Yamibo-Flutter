import 'package:flutter/material.dart';

import '../data/fixtures.dart';
import '../data/library.dart';
import '../design/theme.dart';
import '../design/widgets/button.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/cover.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/rows.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import '../design/widgets/glyph.dart';
import '../design/pressable.dart';

class GalleryPage extends StatelessWidget {
  const GalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final history = YmLibrary.instance.history;

    return Scaffold(
      body: Column(
        children: [
          const YmTopBar(leading: YmBackButton(), title: '控件样板', subtitle: '资产包组件的 Flutter 对照'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _Section(title: '字阶'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('页面主标题 24', style: c.title24),
                      Text('弹层标题 21', style: c.title21),
                      Text('分区小标题 18', style: c.strong18),
                      Text('按钮 / 表格行 14', style: c.body14Regular),
                      Text('标签 / 提示 13', style: c.sub13),
                      Text('次级说明 12', style: c.small12),
                      Text('极小辅助 11', style: c.micro11),
                    ],
                  ),
                ),
                _Section(title: '颜色角色'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final e in <(String, Color)>[
                        ('bg', c.bg),
                        ('card', c.card),
                        ('fill', c.fill),
                        ('brand', c.brand),
                        ('brandTint', c.brandTint),
                        ('accent', c.accent),
                        ('text', c.text),
                        ('text2', c.text2),
                        ('text3', c.text3),
                        ('danger', c.danger),
                        ('green', c.green),
                      ])
                        Container(
                          width: 68,
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            border: Border.all(color: c.border),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            children: [
                              Container(
                                height: 28,
                                decoration: BoxDecoration(
                                  color: e.$2,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(e.$1, style: c.micro11),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                _Section(title: '按钮'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(child: YmButton(label: '主按钮', kind: YmButtonKind.primary, expanded: true, onTap: () {})),
                      const SizedBox(width: 8),
                      Expanded(
                        child: YmButton(
                          label: '次按钮',
                          kind: YmButtonKind.secondary,
                          expanded: true,
                          onTap: () {},
                        ),
                      ),
                    ],
                  ),
                ),
                _Section(title: '胶囊'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,label: '未选中', onTap: () {}),
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,label: '已选中', active: true, onTap: () {}),
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,
                        label: '带方向',
                        active: true,
                        onTap: () {},
                        trailing: const YmSortCaret(desc: true, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                _Section(title: '标签'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      const YmTag('普通'),
                      const YmTag('连载中', brand: true),
                      const YmTag('已完结'),
                      const YmTag('驻站', brand: true),
                    ],
                  ),
                ),
                _Section(title: '封面占位'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      YmCover(title: '大师与玛格丽特', width: 64, height: 84),
                      const SizedBox(width: 12),
                      YmCover(title: '减法累述', width: 96, height: 128),
                      const SizedBox(width: 12),
                      YmCover(title: '不死鸟的救赎', width: 72, height: 96),
                    ],
                  ),
                ),
                _Section(title: '行'),
                YmRankRow(item: YmFixtures.rankNovel.first, onTap: () {}),
                YmRcmdRow(item: YmFixtures.rcmdNovel.first, onTap: () {}),
                if (history.isNotEmpty) YmHistoryRow(entry: history.first, onTap: () {}),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
                  child: YmCardList(
                    children: [
                      YmBookRow(
                        title: '不死鸟的救赎',
                        line: '读到 第12章 灰烬',
                        progress: 0.42,
                        footTag: '小说',
                        footText: '盛雪凌霄',
                        onTap: () {},
                      ),
                    ],
                  ),
                ),
                _Section(title: '状态'),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: YmSkeletonRows(count: 2),
                ),
                const YmStateView(
                  title: '空态标题',
                  desc: '空态说明文字，对应资产包 is-empty。',
                  actionLabel: '操作',
                ),
                _Section(title: '弹层'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: YmButton(
                          label: '确认框',
                          kind: YmButtonKind.secondary,
                          expanded: true,
                          onTap: () => showYmConfirm(
                            context,
                            title: '删除这条记录？',
                            content: '样板内容，确认后不会真的删除。',
                            confirmText: '删除',
                            danger: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: YmButton(
                          label: '目录',
                          kind: YmButtonKind.secondary,
                          expanded: true,
                          onTap: () => showYmSheet<void>(
                            context,
                            builder: (ctx) => YmTocSheet(
                              chapters: YmFixtures.novelDetail.chapters,
                              onPick: (_) => Navigator.of(ctx).pop(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: YmButton(
                          label: '阅读设置',
                          kind: YmButtonKind.secondary,
                          expanded: true,
                          onTap: () => showYmSheet<void>(
                            context,
                            builder: (_) => const YmReaderSettingsSheet(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _Section(title: '滑杆'),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: _SliderDemo(),
                ),
                const YmSampleTip(text: '控件样板 · 颜色 / 字号 / 圆角 / 动效均来自 tokens.dart'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
      child: Text(title, style: c.strong16),
    );
  }
}

class _SliderDemo extends StatefulWidget {
  const _SliderDemo();

  @override
  State<_SliderDemo> createState() => _SliderDemoState();
}

class _SliderDemoState extends State<_SliderDemo> {
  double _value = 0.3;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: _value,
            activeColor: c.brand,
            inactiveColor: c.fill,
            onChanged: (v) => setState(() => _value = v),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text('${(_value * 100).round()}%', style: c.micro11, textAlign: TextAlign.right),
        ),
      ],
    );
  }
}
