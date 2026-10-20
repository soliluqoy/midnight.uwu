import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_wire_spike/cbor_strict.dart';

Uint8List h(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
String hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('RFC 8949 appendix A vectors (supported subset)', () {
    final cases = <String, Object?>{
      '00': 0,
      '01': 1,
      '0a': 10,
      '17': 23,
      '1818': 24,
      '1819': 25,
      '1864': 100,
      '1903e8': 1000,
      '1a000f4240': 1000000,
      '1b000000e8d4a51000': 1000000000000,
      '20': -1,
      '29': -10,
      '3863': -100,
      '3903e7': -1000,
      '40': Uint8List(0),
      '4401020304': Uint8List.fromList([1, 2, 3, 4]),
      '60': '',
      '6161': 'a',
      '6449455446': 'IETF',
      '62c3bc': 'ü',
      '80': <Object?>[],
      '83010203': [1, 2, 3],
      '8301820203820405': [
        1,
        [2, 3],
        [4, 5],
      ],
      'a0': <Object, Object?>{},
      'a201020304': {1: 2, 3: 4},
      'a26161016162820203': {
        'a': 1,
        'b': [2, 3],
      },
      'f4': false,
      'f5': true,
      'f6': null,
    };
    cases.forEach((encoded, value) {
      test('round trip $encoded', () {
        final decoded = cborDecode(h(encoded));
        expect(decoded, value);
        expect(hex(cborEncode(value)), encoded);
      });
    });
  });

  test(
    'map keys are sorted by encoded bytes regardless of insertion order',
    () {
      expect(
        hex(cborEncode({'b': 1, 'a': 2, 10: 3, 2: 4})),
        'a402040a03616102616201',
      );
    },
  );

  group('rejections', () {
    final bad = <String, String>{
      'non-minimal 1-byte int': '1800',
      'non-minimal 2-byte int': '190001',
      'non-minimal 4-byte int': '1a00000001',
      'non-minimal 8-byte int': '1b0000000000000001',
      'indefinite array': '9fff',
      'indefinite byte string': '5fff',
      'indefinite text string': '7fff',
      'float16': 'f93c00',
      'float64': 'fb3ff0000000000000',
      'undefined': 'f7',
      'simple value': 'f0',
      'tag': 'c11a514b67b0',
      'duplicate map key': 'a201020103',
      'unsorted map keys': 'a203040102',
      'trailing bytes': '0000',
      'truncated string': '6261',
      'invalid UTF-8': '62c328',
      'map key is array': 'a1800a',
      'reserved additional info': '1c',
      'uint64 beyond int range': '1bffffffffffffffff',
    };
    bad.forEach((name, encoded) {
      test(
        name,
        () => expect(() => cborDecode(h(encoded)), throwsA(isA<CborError>())),
      );
    });

    test('nesting depth limit', () {
      final deep = Uint8List.fromList([
        ...List.filled(cborMaxDepth + 2, 0x81),
        0x00,
      ]);
      expect(() => cborDecode(deep), throwsA(isA<CborError>()));
    });

    test('container and string length limits', () {
      expect(() => cborDecode(h('9904010000')), throwsA(isA<CborError>()));
      expect(() => cborDecode(h('5a00010001')), throwsA(isA<CborError>()));
    });

    test('encoder rejects unsupported values', () {
      expect(() => cborEncode(1.5), throwsA(isA<CborError>()));
      expect(() => cborEncode({1.5: 1}), throwsA(isA<CborError>()));
    });
  });
}
