import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/top_bar.dart';
import '../design/widgets/glyph.dart';

class StubPage extends StatelessWidget {
  const StubPage({super.key, required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;

    return Scaffold(
      body: Column(
        children: [
          YmTopBar(leading: const YmBackButton(), title: title),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 34),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: c.fill,
                        borderRadius: BorderRadius.circular(YmRadius.box),
                      ),
                      child: Center(
                        child: YmGlyph(kind: YmGlyphKind.inbox, size: 24, color: c.text3),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      note,
                      textAlign: TextAlign.center,
                      style: c.body14Regular.copyWith(color: c.text2, height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
