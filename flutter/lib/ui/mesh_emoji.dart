import 'package:flutter/material.dart';

/// System color-emoji fallbacks so Google Fonts don't hide glyphs (esp. web).
const kEmojiFontFallback = <String>[
  'Apple Color Emoji',
  'Segoe UI Emoji',
  'Noto Color Emoji',
  'Android Emoji',
  'EmojiOne Color',
];

class MeshEmojiCategory {
  const MeshEmojiCategory(this.tab, this.items);
  /// Compact tab glyph shown in the picker chrome.
  final String tab;
  final List<String> items;
}

/// Compact quick-pick set — short lists, frequent chat reactions.
const kMeshEmojiCategories = <MeshEmojiCategory>[
  MeshEmojiCategory('😀', [
    '😀', '😂', '🤣', '😊', '😍', '🥰', '😘', '😎', '🤩', '🥳',
    '😏', '😒', '🙄', '🥺', '😢', '😭', '😤', '😠', '🤯', '😳',
    '🤗', '🤔', '😴', '😷', '😈', '👻', '💀', '🤖', '👽', '💩',
  ]),
  MeshEmojiCategory('👍', [
    '👍', '👎', '👏', '🙌', '🤝', '✌️', '🤞', '🤟', '👌', '🤙',
    '👋', '💪', '🙏', '🫡', '🫶', '👀', '💯', '🔥', '✨', '💥',
  ]),
  MeshEmojiCategory('❤️', [
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💕', '💞',
    '💓', '💗', '💖', '💘', '💔', '❣️', '💋', '❤️‍🔥', '😻', '💌',
  ]),
  MeshEmojiCategory('🎉', [
    '🎉', '🎊', '🎈', '🎁', '🏆', '⭐', '🌟', '⚡', '🌈', '☀️',
    '🌙', '🚀', '✈️', '🎯', '🎮', '🎧', '📷', '💡', '🔑', '🔒',
  ]),
  MeshEmojiCategory('🍕', [
    '🍕', '🍔', '🍟', '🌮', '🍣', '🍜', '🍩', '🍪', '🍿', '🍫',
    '☕', '🍺', '🍻', '🥂', '🍷', '🧃', '🥤', '🧋', '🍎', '🍌',
  ]),
];

final _emojiOnlyRe = RegExp(
  r'^[\s'
  r'\u{1F300}-\u{1FAFF}'
  r'\u{2600}-\u{27BF}'
  r'\u{2300}-\u{23FF}'
  r'\u{2B00}-\u{2BFF}'
  r'\u{1F1E6}-\u{1F1FF}'
  r'\u{200D}\u{FE0E}\u{FE0F}\u{20E3}'
  r'\u{1F3FB}-\u{1F3FF}'
  r'\u{2764}\u{2665}\u{203C}\u{2049}\u{2122}\u{2139}'
  r'\u{2194}-\u{2199}\u{21A9}-\u{21AA}'
  r'\u{231A}-\u{231B}\u{2328}\u{23CF}\u{23E9}-\u{23F3}\u{23F8}-\u{23FA}'
  r'\u{24C2}\u{25AA}-\u{25AB}\u{25B6}\u{25C0}\u{25FB}-\u{25FE}'
  r'\u{2614}-\u{2615}\u{2648}-\u{2653}\u{267F}\u{2693}-\u{26A1}'
  r'\u{26AA}-\u{26AB}\u{26BD}-\u{26BE}\u{26C4}-\u{26C5}\u{26CE}\u{26D4}\u{26EA}'
  r'\u{26F2}-\u{26F5}\u{26FA}-\u{26FD}\u{2702}\u{2705}\u{2708}-\u{270D}'
  r'\u{270F}\u{2712}\u{2714}\u{2716}\u{271D}\u{2721}\u{2728}\u{2733}-\u{2734}'
  r'\u{2744}\u{2747}\u{274C}\u{274E}\u{2753}-\u{2755}\u{2757}\u{2795}-\u{2797}'
  r'\u{27A1}\u{27B0}\u{27BF}\u{2934}-\u{2935}\u{2B05}-\u{2B07}'
  r'\u{2B1B}-\u{2B1C}\u{2B50}\u{2B55}\u{3030}\u{303D}\u{3297}\u{3299}'
  r']+$',
  unicode: true,
);

/// True when [text] is only emoji / ZWJ / VS / whitespace (big-emoji bubble).
bool isEmojiOnlyMessage(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  return _emojiOnlyRe.hasMatch(t);
}

TextStyle meshTextStyle(TextStyle base) {
  return base.copyWith(
    fontFamilyFallback: [
      ...?base.fontFamilyFallback,
      ...kEmojiFontFallback,
    ],
  );
}

/// Insert [emoji] at the current selection in [controller].
void insertEmojiAtCursor(TextEditingController controller, String emoji) {
  final text = controller.text;
  final sel = controller.selection;
  final start = sel.isValid ? sel.start : text.length;
  final end = sel.isValid ? sel.end : text.length;
  final safeStart = start.clamp(0, text.length);
  final safeEnd = end.clamp(0, text.length);
  final next = text.replaceRange(safeStart, safeEnd, emoji);
  final caret = safeStart + emoji.length;
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: caret),
  );
}
