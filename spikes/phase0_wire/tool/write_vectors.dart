import 'dart:convert';
import 'dart:io';

import 'package:vault_wire_spike/vectors.dart';

Future<void> main() async {
  final vectors = await buildVectors();
  File('test/vectors.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(vectors)}\n',
  );
  stdout.writeln('wrote test/vectors.json');
}
