import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'probe_app.dart';
import 'webrtc_adapter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initializeProbeWebRTC();
  runApp(const ProbeApp());
}
