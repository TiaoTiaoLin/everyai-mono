/// A scan of skill, agent and custom command text for instructions a reviewer
/// may not see or may read past: hidden characters, HTML comments that talk
/// to the model, and lines telling the agent to ignore the user, keep things
/// from the user, or send private data out.
///
/// Findings are advice for the trust and import reviews: nothing is blocked.
/// The phrase rules are heuristics (rephrasing, other languages and encodings
/// pass), so each one needs two parts to stay quiet on ordinary prose.
library;

import '../../../core/security/untrusted.dart';

enum InstructionFlag {
  hiddenText('hidden characters'),
  htmlComment('an HTML comment'),
  ignoresUser('text telling the agent to ignore the user or its rules'),
  hidesFromUser('text telling the agent to keep something from the user'),
  sendsData('text that may send private data out');

  const InstructionFlag(this.label);
  final String label;
}

/// One flagged spot: [line] is 1-based in [file], front matter included.
typedef InstructionFinding = ({String file, int line, InstructionFlag flag, String excerpt});

/// Findings kept per file.
const maxFindingsPerFile = 20;

final _comment = RegExp(r'<!--([\s\S]*?)(?:-->|$)');
final _phrases = <InstructionFlag, List<RegExp>>{
  InstructionFlag.ignoresUser: [
    _rule(
      r"\b(?:ignore|disregard|forget|override)\b.{0,40}?\b(?:previous|prior|above|earlier|all|other|system|the user'?s?)"
      r'\b.{0,30}?\b(?:instructions?|rules|prompts?|requests?)\b',
    ),
    _rule(r'\byou are now (?:a |an )?(?:different|new|unrestricted|jailbroken|free|no longer)\b'),
    _rule(r'\bnew (?:system )?instructions\s*:|\b(?:new|updated|real) system (?:prompt|instructions)\b'),
  ],
  InstructionFlag.hidesFromUser: [
    _rule(r"\b(?:do not|don'?t|never)\s+(?:tell|inform|mention|reveal|let|alert|notify)\b.{0,40}?\buser\b"),
    _rule(r'\bwithout (?:telling|asking|informing|notifying|alerting) (?:the )?user\b'),
    _rule(r'\b(?:hide|conceal|keep)\b.{0,40}?\bfrom (?:the )?user\b'),
    _rule(r'\b(?:secretly|covertly)\b'),
  ],
  InstructionFlag.sendsData: [
    _rule(r'\b(?:curl|wget|nc|ncat)\b.*(?:\$\{?\w*(?:key|token|secret|pass)|@\S*(?:\.ssh|\.env|\.aws))'),
    _rule(r'!\[[^\]]*\]\(\s*\w+://[^)\s]*[$\{<]'),
  ],
};

RegExp _rule(String pattern) => RegExp(pattern, caseSensitive: false);

// sendsData also fires on a sending verb and a private-data noun in one sentence (two plain scans, no backtracking).
final _sendVerb = _rule(r'\b(?:send|upload|forward|exfiltrate|leak|transmit)\w*\b');
final _privateData = _rule(
  r'\.env\b|\bapi[ _-]?keys?\b|\btokens?\b|\bsecrets?\b|\bcredentials?\b|\bpasswords?\b|\bssh keys?\b|'
  r'~/\.ssh|~/\.aws|\bcookies\b|\b(?:chat|conversation) history\b',
);

/// What in [text] (the contents of [file]) may be trying to steer the agent; at most [maxFindingsPerFile].
List<InstructionFinding> scanInstructions(String text, {required String file}) {
  final out = <InstructionFinding>[];
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  void add(int line, InstructionFlag flag, String excerpt) {
    if (out.any((f) => f.line == line && f.flag == flag)) return;
    out.add((file: file, line: line, flag: flag, excerpt: _short(excerpt)));
  }

  for (var i = 0; i < lines.length; i++) {
    final l = i == 0 ? lines[i].replaceFirst('\uFEFF', '') : lines[i];
    if (hiddenIn(l).isNotEmpty) add(i + 1, InstructionFlag.hiddenText, revealHidden(l));
  }
  final clean = stripHidden(lines.join('\n'));
  for (final m in _comment.allMatches(clean)) {
    final words = RegExp(r'\S+').allMatches(m.group(1)!).length;
    if (words >= 4) add('\n'.allMatches(clean.substring(0, m.start)).length + 1, InstructionFlag.htmlComment, m[0]!);
  }
  final cleanLines = clean.split('\n');
  for (var i = 0; i < cleanLines.length; i++) {
    for (final sentence in cleanLines[i].split(RegExp(r'(?<=[.!?])\s+'))) {
      final s = sentence.replaceAll(RegExp(r'\s+'), ' ');
      for (final MapEntry(key: flag, value: rules) in _phrases.entries) {
        if (rules.any((r) => r.hasMatch(s)) ||
            flag == InstructionFlag.sendsData && _sendVerb.hasMatch(s) && _privateData.hasMatch(s)) {
          add(i + 1, flag, cleanLines[i]);
        }
      }
    }
  }
  out.sort((a, b) => a.line != b.line ? a.line.compareTo(b.line) : a.flag.index.compareTo(b.flag.index));
  return out.length > maxFindingsPerFile ? out.sublist(0, maxFindingsPerFile) : out;
}

/// [text] with each hidden character shown as `⟦U+200B⟧`, and a run of tag
/// characters (invisible ASCII look-alikes) decoded as `⟦hidden: …⟧`.
String revealHidden(String text) {
  if (hiddenIn(text).isEmpty && !text.contains('\uFEFF')) return text;
  final b = StringBuffer();
  final tags = StringBuffer();
  void flushTags() {
    if (tags.isEmpty) return;
    b.write('⟦hidden: $tags⟧');
    tags.clear();
  }

  for (final r in text.runes) {
    if (r >= 0xE0000 && r <= 0xE007F) {
      if (r >= 0xE0020 && r <= 0xE007E) tags.writeCharCode(r - 0xE0000);
      continue;
    }
    flushTags();
    if (r == 0xFEFF || hiddenIn(String.fromCharCode(r)).isNotEmpty) {
      b.write('⟦U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}⟧');
    } else {
      b.writeCharCode(r);
    }
  }
  flushTags();
  return b.toString();
}

String _short(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= 120 ? t : '${t.substring(0, 117)}...';
}

/// One warning line for one file's findings, or null when there are none:
/// "Hidden or suspicious text: hidden characters on line 4; an HTML comment on line 9. Review before trusting."
String? findingsWarning(List<InstructionFinding> findings) {
  if (findings.isEmpty) return null;
  final byFlag = <InstructionFlag, List<int>>{};
  for (final f in findings) {
    (byFlag[f.flag] ??= []).add(f.line);
  }
  final parts = [
    for (final MapEntry(key: flag, value: lines) in byFlag.entries)
      '${flag.label} on ${lines.length == 1 ? 'line' : 'lines'} ${lines.take(5).join(', ')}'
          '${lines.length > 5 ? ' and more' : ''}',
  ];
  return 'Hidden or suspicious text: ${parts.join('; ')}. Review before trusting.';
}

/// The findings as review text: a lead-in and up to [max] bullets, the rest counted.
String findingsMessage(List<InstructionFinding> findings, {int max = 8}) {
  final b = StringBuffer('We found text that may be trying to steer the agent:');
  for (final f in findings.take(max)) {
    b.write('\n• ${f.file.isEmpty ? '' : '${f.file} '}line ${f.line}: ${f.flag.label}: "${f.excerpt}"');
  }
  if (findings.length > max) b.write('\n…and ${findings.length - max} more.');
  return b.toString();
}

/// The note added where hidden characters were removed from text handed to the model; null when [original] had none.
String? hiddenRemovedNote(String original) {
  final kinds = hiddenIn(original);
  if (kinds.isEmpty) return null;
  final lines = [
    for (final (i, l) in original.split('\n').indexed)
      if (hiddenIn(l).isNotEmpty) i + 1,
  ];
  return '[Hidden characters removed (${kinds.map((k) => k.label).join(', ')}) on '
      '${lines.length == 1 ? 'line' : 'lines'} ${lines.take(10).join(', ')}${lines.length > 10 ? ', …' : ''}.]';
}
