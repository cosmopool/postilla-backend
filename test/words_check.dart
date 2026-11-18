// Runs the Dart normalization `zig build dart` generates (zig-out/dart/words_norm.dart) on
// the AC-6, AC-7 and AC-8 inputs. Exits 1 when a result differs from tilla.md (Words), and
// prints one line per input — the input, its normalization and its lookup keys,
// tab-separated — so test/words.zig can check each line against the Zig functions.
import 'dart:io';

import '../zig-out/dart/words_norm.dart';

const normalized = {
  'È GIÀ così': 'e gia cosi',
  'perché': 'perche',
  'Straße': 'strasse',
  'Œuvre': 'oeuvre',
  'Ærø': 'aero',
  'Łódź': 'lodz',
  'Đorđe': 'dorde',
  'Ħal': 'hal',
  'l’aria': "l'aria",
  'c‑è': 'c-e',
  '1860, 3.5!? (x)': '1860, 3.5!? (x)',
};

const keys = {
  "l'aria": ["l'aria", 'aria'],
  'Dell’Anno': ['Dell’Anno', "dell'anno", 'Anno', 'anno'],
  'casa': ['casa'],
  "po'": ["po'"],
};

void main() {
  final inputs = [...normalized.keys, ...keys.keys];
  for (var cp = 0xC0; cp <= 0x24F; cp++) {
    if (cp != 0xD7 && cp != 0xF7) inputs.add(String.fromCharCode(cp));
  }

  void fail(String what) {
    stderr.writeln(what);
    exitCode = 1;
  }

  normalized.forEach((input, want) {
    final got = normalize(input);
    if (got != want) fail('normalize($input) = $got, want $want');
  });
  keys.forEach((input, want) {
    final got = lookupKeys(input);
    if (got.join('|') != want.join('|')) fail('lookupKeys($input) = $got, want $want');
  });
  for (final letter in inputs.skip(normalized.length + keys.length)) {
    final once = normalize(letter);
    if (!RegExp(r'^[a-z]+$').hasMatch(once)) fail('normalize($letter) = $once, not ASCII letters');
    if (normalize(once) != once) fail('normalize($letter) = $once is not stable');
  }

  for (final input in inputs) {
    print([input, normalize(input), ...lookupKeys(input)].join('\t'));
  }
}
