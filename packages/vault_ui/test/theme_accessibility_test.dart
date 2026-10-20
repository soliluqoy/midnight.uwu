import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_ui/vault_ui.dart';

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return first > second
      ? (first + .05) / (second + .05)
      : (second + .05) / (first + .05);
}

void main() {
  for (final dark in [false, true]) {
    for (final highContrast in [false, true]) {
      test(
        'semantic text remains readable: dark=$dark highContrast=$highContrast',
        () {
          final scheme = vaultTheme(
            dark: dark,
            highContrast: highContrast,
          ).colorScheme;
          for (final background in [
            scheme.surface,
            scheme.surfaceContainerLowest,
            scheme.surfaceContainerHighest,
          ]) {
            expect(
              _contrast(scheme.onSurface, background),
              greaterThanOrEqualTo(highContrast ? 7 : 4.5),
            );
            expect(
              _contrast(scheme.onSurfaceVariant, background),
              greaterThanOrEqualTo(highContrast ? 7 : 4.5),
            );
          }
          for (final pair in [
            (scheme.onPrimary, scheme.primary),
            (scheme.onPrimaryContainer, scheme.primaryContainer),
            (scheme.onErrorContainer, scheme.errorContainer),
          ]) {
            expect(_contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
          }
          expect(
            _contrast(scheme.outline, scheme.surfaceContainerLowest),
            greaterThanOrEqualTo(3),
          );
        },
      );
    }
  }
}
