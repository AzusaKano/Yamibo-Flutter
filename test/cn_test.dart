import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/cn.dart';

/// 简繁切换回归（曾出现：正文选「简体」时繁体原文不转）。
///
/// 原来 `readerText` 在「简体」分支直接返回原文，只做得到 简 → 繁。
/// 现在的契约有三条：
/// ① 双向：目标字形跟原文不一致就转（不只是简 → 繁）；
/// ② 一致就原样返回 —— 字表是**逐字**替换的，`面→麵`、`里→裏` 再转一遍会改坏繁体原文；
/// ③ 原文字形按**整章**判一次后传进来，短段不参与投票（否则会被判反）。
void main() {
  // 设置弹层预览用的同一句样例（简 / 繁两版，11 个差异字）
  const simp = '阳光照射在路旁的田野与远处延绵的山峰上，映照出郁郁葱葱的绿色。';
  const trad = '陽光照射在路旁的田野與遠處延綿的山峰上，映照出鬱鬱蔥蔥的綠色。';

  group('字典方向', () {
    test('简体 → 繁体', () {
      expect(toTraditional(simp), trad);
    });

    test('繁体 → 简体', () {
      expect(toSimplified(trad), simp);
    });
  });

  group('isTraditionalText', () {
    test('简体样本判为简体', () {
      expect(isTraditionalText(simp), isFalse);
    });

    test('繁体样本判为繁体', () {
      expect(isTraditionalText(trad), isTrue);
    });

    test('「面」「里」这类简繁同形字不把繁体正文判成简体', () {
      // 两个都是字表里的「简体专用字」，但在繁体正文里照样这么写；
      // 整章投票时繁体专用字远多于它们，判不掉。
      expect(
        isTraditionalText('我們站在牆角裏，誰都沒有說話。對面那棟樓的燈還亮着，像是有人在等誰回家。'),
        isTrue,
      );
    });

    test('没有差异字的短句判为简体（不误判成繁体）', () {
      expect(isTraditionalText('（一）'), isFalse);
      expect(isTraditionalText(''), isFalse);
    });
  });

  group('readerText', () {
    test('简体原文 + 简体 = 原样', () {
      expect(readerText(simp, false), simp);
    });

    test('简体原文 + 繁体 = 转过去', () {
      expect(readerText(simp, true), trad);
    });

    test('繁体原文 + 简体 = 转回来（本次修的 bug）', () {
      expect(readerText(trad, false), simp);
    });

    test('繁体原文 + 繁体 = 原样，不二次转换', () {
      // 逐字表里 面→麵、里→裏，再转一遍就会写出「後麵」「角落裏」
      expect(readerText(trad, true), trad);
      expect(readerText('他坐在對面，走了三里路。', true), '他坐在對面，走了三里路。');
    });

    test('整章判定优先于逐段判定', () {
      // 短段自己投票会打平（判成简体）；整章判好传进来就不该动它
      expect(
        readerText('（一）', true, sourceTraditional: true),
        '（一）',
      );
      expect(
        readerText('「……」', false, sourceTraditional: false),
        '「……」',
      );
    });

    test('空串原样返回', () {
      expect(readerText('', false), '');
      expect(readerText('', true), '');
    });
  });
}
