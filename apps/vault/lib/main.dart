import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'package:vault/platform/instance_lock.dart';
import 'package:vault/platform/protected_store.dart';
import 'package:vault/production/vault_app.dart';
import 'package:vault/production/vault_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Lora',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  await _start();
}

bool _loading = false;
Future<void> _start() async {
  if (_loading) return;
  _loading = true;
  try {
    final runtime = await VaultRuntime.load(store: const ProtectedStore());
    runApp(VaultApp(runtime: runtime));
  } on VaultAlreadyRunning {
    runApp(const VaultStartupFailure(retry: _start, alreadyRunning: true));
  } on Object catch (error, stack) {
    // Never log exception values: storage messages may contain private records.
    debugPrint('Vault startup failed (${error.runtimeType}); stack:\n$stack');
    if (error is PlatformException) {
      final exceptionClass = RegExp(
        r'^(?:Caused by: )?([\w.$]+(?:Exception|Error))(?::|$)',
      );
      for (final line in error.stacktrace?.split('\n') ?? const <String>[]) {
        final frame = line.trim();
        if (frame.startsWith('at ')) {
          debugPrint('Vault startup native frame: $frame');
        } else {
          final cause = exceptionClass.firstMatch(frame);
          if (cause != null) {
            debugPrint('Vault startup native cause: ${cause[1]}');
          }
        }
      }
    }
    // Stay offline until all persisted state loads successfully.
    runApp(const VaultStartupFailure(retry: _start));
  } finally {
    _loading = false;
  }
}
