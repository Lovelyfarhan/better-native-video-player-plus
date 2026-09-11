import 'package:better_native_video_player_plus/better_native_video_player_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// Round-trip and decode coverage for the provider-neutral advertising data
/// models. The wire maps the models produce must reconstruct through their
/// `fromMap` factories unchanged, because native ad adapters echo break
/// payloads back to Dart inside advertisement events.
void main() {
  test('configuration defaults stay enabled with auto tag detection', () {
    final configuration = NativeVideoPlayerAdConfiguration(
      adTagUrl: Uri.parse('https://ads.example.com/tag'),
    );

    expect(configuration.enabled, isTrue);
    expect(configuration.tagType, NativeVideoPlayerAdTagType.auto);
    expect(configuration.resumeContentOnError, isTrue);
    // The wire form omits default-valued fields: native parsers must treat
    // a missing `enabled` as true.
    expect(configuration.toMap(), <String, Object>{
      'adTagUrl': 'https://ads.example.com/tag',
      'tagType': 'auto',
    });
  });

  test('ad breaks round-trip through the wire map', () {
    final breakInfo = NativeVideoPlayerAdBreak.midRoll(
      id: 'mid-roll-1',
      position: const Duration(minutes: 4),
      adTagUrl: Uri.parse('https://ads.example.com/break-tag'),
      skipConfiguration: const NativeVideoPlayerAdSkipConfiguration(
        allowUserSkip: false,
        skipAfter: Duration(seconds: 10),
      ),
    );

    final restored = NativeVideoPlayerAdBreak.fromMap(breakInfo.toMap());

    expect(restored.id, 'mid-roll-1');
    expect(restored.type, NativeVideoPlayerAdBreakType.midRoll);
    expect(restored.position, const Duration(minutes: 4));
    expect(restored.adTagUrl, Uri.parse('https://ads.example.com/break-tag'));
    expect(restored.skipConfiguration?.allowUserSkip, isFalse);
    expect(restored.skipConfiguration?.skipAfter, const Duration(seconds: 10));
  });

  test('minimal breaks round-trip without optional fields', () {
    const breakInfo = NativeVideoPlayerAdBreak.postRoll(id: 'post-roll');

    final restored = NativeVideoPlayerAdBreak.fromMap(breakInfo.toMap());

    expect(restored.id, 'post-roll');
    expect(restored.type, NativeVideoPlayerAdBreakType.postRoll);
    expect(restored.position, isNull);
    expect(restored.adTagUrl, isNull);
    expect(restored.skipConfiguration, isNull);
  });

  test('skip configuration round-trips with its default policy', () {
    const skip = NativeVideoPlayerAdSkipConfiguration();

    expect(skip.toMap(), <String, Object>{'allowUserSkip': true});
    final restored = NativeVideoPlayerAdSkipConfiguration.fromMap(skip.toMap());
    expect(restored.allowUserSkip, isTrue);
    expect(restored.skipAfter, isNull);

    const skipAfter = NativeVideoPlayerAdSkipConfiguration(
      skipAfter: Duration(seconds: 7),
    );
    expect(
      NativeVideoPlayerAdSkipConfiguration.fromMap(skipAfter.toMap()).skipAfter,
      const Duration(seconds: 7),
    );
  });

  test('break identity invariants are enforced', () {
    expect(
      () => NativeVideoPlayerAdBreak(
        id: 'mid-roll-1',
        type: NativeVideoPlayerAdBreakType.midRoll,
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => NativeVideoPlayerAdBreak(
        id: '',
        type: NativeVideoPlayerAdBreakType.preRoll,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('event decoding preserves unknown provider event names', () {
    final event = NativeVideoPlayerAdEvent.fromMap(<String, Object>{
      'adEventType': 'futureProviderEvent',
    });

    expect(event.type, NativeVideoPlayerAdEventType.unknown);
    expect(event.rawType, 'futureProviderEvent');
    expect(event.adBreak, isNull);
    expect(event.metadata, isNull);
    expect(event.error, isNull);
  });

  test('event decoding restores served-ad metadata and progress', () {
    final event = NativeVideoPlayerAdEvent.fromMap(<String, Object>{
      'adEventType': 'adProgress',
      'positionMs': 12000,
      'durationMs': 30000,
      'metadata': <String, Object>{
        'adId': 'ad-7',
        'creativeId': 'creative-7',
        'adSystem': 'AdSys',
        'title': 'Promo',
        'advertiserName': 'ACME',
        'clickThroughUrl': 'https://ad.example.com/landing',
      },
    });

    expect(event.type, NativeVideoPlayerAdEventType.adProgress);
    expect(event.position, const Duration(seconds: 12));
    expect(event.duration, const Duration(seconds: 30));
    expect(event.metadata?.adId, 'ad-7');
    expect(event.metadata?.creativeId, 'creative-7');
    expect(event.metadata?.adSystem, 'AdSys');
    expect(event.metadata?.advertiserName, 'ACME');
    expect(
      event.metadata?.clickThroughUrl,
      Uri.parse('https://ad.example.com/landing'),
    );
  });

  test('event decoding restores quartiles and skip metadata', () {
    final event = NativeVideoPlayerAdEvent.fromMap(<String, Object>{
      'adEventType': 'firstQuartile',
      'metadata': <String, Object>{
        'adId': 'ad-8',
        'isSkippable': true,
        'skipTimeOffsetMs': 5000,
      },
    });

    expect(event.type, NativeVideoPlayerAdEventType.firstQuartile);
    expect(event.metadata?.isSkippable, isTrue);
    expect(event.metadata?.skipTimeOffset, const Duration(seconds: 5));
    expect(
      NativeVideoPlayerAdEvent.fromMap(<String, Object>{
        'adEventType': 'midpoint',
      }).type,
      NativeVideoPlayerAdEventType.midpoint,
    );
    expect(
      NativeVideoPlayerAdEvent.fromMap(<String, Object>{
        'adEventType': 'thirdQuartile',
      }).type,
      NativeVideoPlayerAdEventType.thirdQuartile,
    );
  });

  test('event decoding restores timestamp and content identity', () {
    final timestamp = DateTime.utc(2026, 9, 9, 12, 30);
    final event = NativeVideoPlayerAdEvent.fromMap(<String, Object>{
      'adEventType': 'adStarted',
      'timestampMs': timestamp.millisecondsSinceEpoch,
      'contentId': 'episode-7',
      'contentTitle': 'Episode 7',
      'contentUrl': 'https://content.example.com/episode-7.m3u8',
      'adBreakId': 'pre-roll',
    });

    expect(event.timestamp, timestamp);
    expect(event.contentId, 'episode-7');
    expect(event.contentTitle, 'Episode 7');
    expect(
      event.contentUrl,
      Uri.parse('https://content.example.com/episode-7.m3u8'),
    );
    expect(event.adBreakId, 'pre-roll');
  });

  test('ad errors decode code, message and details', () {
    final error = NativeVideoPlayerAdError.fromMap(<String, Object>{
      'code': 'VAST_LOAD_TIMEOUT',
      'message': 'The tag did not respond in time.',
      'details': <String, Object>{'attempt': 2},
    });

    expect(error.code, 'VAST_LOAD_TIMEOUT');
    expect(error.message, 'The tag did not respond in time.');
    expect(error.details, <String, Object>{'attempt': 2});
  });
}
