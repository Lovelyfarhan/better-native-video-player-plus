import 'package:better_native_video_player_plus/src/advertising/native_video_player_ad_configuration.dart';
import 'package:better_native_video_player_plus/src/advertising/native_video_player_ad_event.dart';
import 'package:better_native_video_player_plus/src/platform/video_player_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('native_video_player');
  final calls = <MethodCall>[];
  late VideoPlayerMethodChannel platform;

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    platform = VideoPlayerMethodChannel(primaryPlatformViewId: 812);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('ad platform commands use the existing player method channel', () async {
    final configuration = NativeVideoPlayerAdConfiguration.vast(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
    );

    await platform.initializeAdvertisement(configuration);
    await platform.requestAdvertisements();
    await platform.startAdvertisement();
    await platform.pauseAdvertisement();
    await platform.resumeAdvertisement();
    await platform.stopAdvertisement();
    await platform.destroyAdvertisement();

    expect(calls.map((call) => call.method), <String>[
      'advertisementInitialize',
      'advertisementRequestAds',
      'advertisementStart',
      'advertisementPause',
      'advertisementResume',
      'advertisementStop',
      'advertisementDestroy',
    ]);
    expect(calls.first.arguments, <String, Object>{
      'viewId': 812,
      'adConfiguration': configuration.toMap(),
    });
    for (final call in calls.skip(1)) {
      expect(call.arguments, <String, Object>{'viewId': 812});
    }
  });

  test('ad events reuse the controller event envelope', () {
    final event = platform.decodeEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{
        'adEventType': 'adStarted',
        'adBreakId': 'mid-roll-1',
      },
    });

    expect(event.type, NativeVideoPlayerAdEventType.adStarted);
    expect(event.adBreakId, 'mid-roll-1');
  });
}
