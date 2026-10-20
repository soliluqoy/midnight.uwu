/// Private contact signaling and opt-in signed public MQTT metadata discovery.
library;

export 'src/client.dart';
export 'src/presence.dart'
    show
        PublicPresenceRecord,
        maxPublicPresenceBytes,
        verifyPublicPresenceRecord;
export 'src/strategies/manual.dart';
export 'src/strategies/mqtt.dart';
export 'src/strategy.dart';
