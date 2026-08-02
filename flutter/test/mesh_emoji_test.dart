import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline/ui/mesh_emoji.dart';

void main() {
  test('emoji-only messages detected', () {
    expect(isEmojiOnlyMessage('🔥'), isTrue);
    expect(isEmojiOnlyMessage('👍👍'), isTrue);
    expect(isEmojiOnlyMessage('❤️‍🔥'), isTrue);
    expect(isEmojiOnlyMessage('  😂  '), isTrue);
  });

  test('mixed text is not emoji-only', () {
    expect(isEmojiOnlyMessage('hi 🔥'), isFalse);
    expect(isEmojiOnlyMessage('ok'), isFalse);
    expect(isEmojiOnlyMessage(''), isFalse);
  });

  test('insertEmojiAtCursor replaces selection', () {
    final c = TextEditingController(text: 'ab');
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 1);
    insertEmojiAtCursor(c, '😀');
    expect(c.text, 'a😀b');
    expect(c.selection.baseOffset, 1 + '😀'.length);
  });
}
