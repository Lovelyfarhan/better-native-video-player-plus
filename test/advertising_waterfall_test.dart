import 'package:better_native_video_player_plus/better_native_video_player_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// Coverage for the ordered VAST-tag waterfall.
///
/// The waterfall is pure Dart policy on top of the native adapter, so these
/// tests drive it directly with a fake `requestTag` and verify which tags are
/// requested, in what order, and which events are emitted. The native failure
/// semantics (no fill, timeout, fatal error) are the only inputs that matter.
void main() {
  Uri tag(int index) => Uri.parse('https://ads.example.com/tag-$index.xml');

  NativeVideoPlayerAdConfiguration configuration({
    List<Uri>? vastTags,
    Duration perTagTimeout = const Duration(seconds: 8),
    bool includeSingleTagAsFallback = false,
  }) => NativeVideoPlayerAdConfiguration.vast(
    adTagUrl: tag(0),
    adBreaks: const <NativeVideoPlayerAdBreak>[
      NativeVideoPlayerAdBreak.preRoll(id: 'pre'),
    ],
    vastTags: vastTags ?? const <Uri>[],
    perTagTimeout: perTagTimeout,
    includeSingleTagAsFallback: includeSingleTagAsFallback,
  );

  group('tag list', () {
    test('primary tag is always first and fallbacks follow in order', () {
      final config = configuration(vastTags: <Uri>[tag(1), tag(2)]);

      expect(config.waterfallTags, <Uri>[tag(0), tag(1), tag(2)]);
      expect(config.hasTagWaterfall, isTrue);
    });

    test('duplicate and repeated primary tags are de-duplicated', () {
      final config = configuration(vastTags: <Uri>[tag(0), tag(1), tag(1)]);

      expect(config.waterfallTags, <Uri>[tag(0), tag(1)]);
    });

    test('a single tag has no waterfall by default', () {
      final config = configuration();

      expect(config.waterfallTags, <Uri>[tag(0)]);
      expect(config.hasTagWaterfall, isFalse);
    });

    test('a single tag can opt into being retried once', () {
      final config = configuration(includeSingleTagAsFallback: true);

      expect(config.waterfallTags, <Uri>[tag(0), tag(0)]);
      expect(config.hasTagWaterfall, isTrue);
    });

    test('vastWaterfall builds a configuration from an ordered list', () {
      final config = NativeVideoPlayerAdConfiguration.vastWaterfall(
        vastTags: <Uri>[tag(0), tag(1)],
      );

      expect(config.adTagUrl, tag(0));
      expect(config.tagType, NativeVideoPlayerAdTagType.vast);
      expect(config.waterfallTags, <Uri>[tag(0), tag(1)]);
    });

    test('vastWaterfall rejects an empty list', () {
      expect(
        () => NativeVideoPlayerAdConfiguration.vastWaterfall(vastTags: <Uri>[]),
        throwsArgumentError,
      );
    });

    test('the wire map carries the ordered tags and per-tag timeout', () {
      final config = configuration(vastTags: <Uri>[tag(1), tag(2)]);

      expect(config.toMap()['vastTags'], <String>[
        'https://ads.example.com/tag-1.xml',
        'https://ads.example.com/tag-2.xml',
      ]);
      expect(config.toMap()['perTagTimeoutMs'], 8000);
    });
  });

  group('waterfall progression', () {
    late List<Uri> requested;
    late List<NativeVideoPlayerAdEvent> events;
    late NativeVideoPlayerAdWaterfallManager manager;

    NativeVideoPlayerAdWaterfallManager build({
      int tagCount = 3,
      bool continueOnFatalErrors = false,
      Future<void> Function()? onTagAbandoned,
      Duration perTagTimeout = const Duration(seconds: 8),
    }) {
      requested = <Uri>[];
      events = <NativeVideoPlayerAdEvent>[];
      final built = NativeVideoPlayerAdWaterfallManager(
        requestTag: (tagConfiguration) async {
          requested.add(tagConfiguration.adTagUrl);
        },
        onTagAbandoned: onTagAbandoned,
        continueOnFatalErrors: continueOnFatalErrors,
      );
      built.events.listen(events.add);
      return built;
    }

    NativeVideoPlayerAdError error(String code) => NativeVideoPlayerAdError(
      code: code,
      message: 'provider message for $code',
    );

    tearDown(() async {
      await manager.dispose();
    });

    test('requests the first tag immediately on start', () async {
      manager = build();
      manager.start(
        configuration(
          vastTags: <Uri>[tag(1), tag(2)],
          perTagTimeout: Duration.zero,
        ),
      );
      await pumpEventQueue();

      expect(requested, <Uri>[tag(0)]);
      expect(manager.currentIndex, 0);
      expect(manager.totalTags, 3);
    });

    test('no fill on tag 1 advances through tag 2 to tag 3', () async {
      manager = build();
      manager.start(configuration(vastTags: <Uri>[tag(1), tag(2)]));
      await pumpEventQueue();

      manager.onTagNoFill(error('VAST_EMPTY_RESPONSE'));
      await pumpEventQueue();
      expect(requested.last, tag(1));
      expect(manager.currentIndex, 1);

      manager.onTagNoFill(error('VAST_NO_ADS_AFTER_WRAPPER'));
      await pumpEventQueue();
      expect(requested.last, tag(2));
      expect(manager.currentIndex, 2);

      expect(events.map((event) => event.type), <NativeVideoPlayerAdEventType>[
        NativeVideoPlayerAdEventType.tagRequested,
        NativeVideoPlayerAdEventType.tagFailed,
        NativeVideoPlayerAdEventType.tagRequested,
        NativeVideoPlayerAdEventType.tagFailed,
        NativeVideoPlayerAdEventType.tagRequested,
      ]);
      expect(
        events
            .where(
              (event) =>
                  event.type == NativeVideoPlayerAdEventType.tagRequested,
            )
            .map((event) => event.adTagUrl),
        <Uri>[tag(0), tag(1), tag(2)],
      );
    });

    test('exhausting every tag ends the waterfall with a reason', () async {
      NativeVideoPlayerAdWaterfallStopReason? stopReason;
      requested = <Uri>[];
      events = <NativeVideoPlayerAdEvent>[];
      manager = NativeVideoPlayerAdWaterfallManager(
        requestTag: (tagConfiguration) async {
          requested.add(tagConfiguration.adTagUrl);
        },
        callbacks: NativeVideoPlayerAdWaterfallCallbacks(
          onAllTagsFailed: (reason) => stopReason = reason,
        ),
      );
      manager.events.listen(events.add);

      manager.start(configuration(vastTags: <Uri>[tag(1)]));
      await pumpEventQueue();
      manager.onTagNoFill(error('VAST_EMPTY_RESPONSE'));
      await pumpEventQueue();
      manager.onTagNoFill(error('VAST_EMPTY_RESPONSE'));
      await pumpEventQueue();

      expect(requested, <Uri>[tag(0), tag(1)]);
      expect(
        stopReason,
        NativeVideoPlayerAdWaterfallStopReason.allTagsExhausted,
      );
      expect(manager.isRunning, isFalse);
      expect(events.last.type, NativeVideoPlayerAdEventType.waterfallExhausted);
      expect(events.last.metadata?.adSystem, contains('allTagsExhausted'));
    });

    test(
      'advancing abandons the previous attempt before the next tag',
      () async {
        var abandoned = 0;
        manager = build(onTagAbandoned: () async => abandoned++);

        manager.start(configuration(vastTags: <Uri>[tag(1)]));
        await pumpEventQueue();
        manager.onTagNoFill(error('VAST_EMPTY_RESPONSE'));
        await pumpEventQueue();

        expect(abandoned, 1);
        expect(requested, <Uri>[tag(0), tag(1)]);
      },
    );

    test('per-tag timeout is treated as no fill and advances', () async {
      manager = build(perTagTimeout: const Duration(milliseconds: 20));
      manager.start(
        configuration(
          vastTags: <Uri>[tag(1)],
          perTagTimeout: const Duration(milliseconds: 20),
        ),
      );
      await pumpEventQueue();

      // Wait past both deadlines without reporting any provider outcome. Both
      // tags time out independently: tag 0 advances to tag 1, then tag 1 ends
      // the waterfall, because neither server answered.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(requested, <Uri>[tag(0), tag(1)]);
      final timeouts = events.where(
        (event) =>
            event.type == NativeVideoPlayerAdEventType.tagFailed &&
            event.error?.code == 'AD_TAG_TIMEOUT',
      );
      expect(timeouts, hasLength(2));
      expect(timeouts.map((event) => event.tagIndex), <int>[0, 1]);
      expect(events.last.type, NativeVideoPlayerAdEventType.waterfallExhausted);
      expect(manager.isRunning, isFalse);
    });

    test('a fatal non-fill error stops the waterfall by default', () async {
      manager = build();
      manager.start(configuration(vastTags: <Uri>[tag(1)]));
      await pumpEventQueue();

      manager.onTagFailed(error('VAST_SCHEMA_VALIDATION_ERROR'));
      await pumpEventQueue();

      expect(requested, <Uri>[tag(0)]);
      expect(manager.isRunning, isFalse);
      expect(events.last.type, NativeVideoPlayerAdEventType.waterfallExhausted);
      expect(events.last.metadata?.adSystem, contains('fatalError'));
    });

    test('continueOnFatalErrors keeps advancing past a fatal error', () async {
      manager = build(continueOnFatalErrors: true);
      manager.start(configuration(vastTags: <Uri>[tag(1)]));
      await pumpEventQueue();

      manager.onTagFailed(error('VAST_SCHEMA_VALIDATION_ERROR'));
      await pumpEventQueue();

      expect(requested, <Uri>[tag(0), tag(1)]);
    });

    test('a playback-time error still falls through to the next tag', () async {
      manager = build();
      manager.start(
        configuration(vastTags: <Uri>[tag(1)], perTagTimeout: Duration.zero),
      );
      await pumpEventQueue();

      manager.onTagLoaded();
      manager.onPlaybackError(error('AD_PLAYER_ERROR'));
      await pumpEventQueue();

      expect(requested, <Uri>[tag(0), tag(1)]);
    });

    test('an ad that starts playing resolves the waterfall', () async {
      manager = build();
      manager.start(configuration(vastTags: <Uri>[tag(1)]));
      await pumpEventQueue();

      manager.onTagLoaded();
      manager.onAdStarted();
      await pumpEventQueue();

      expect(manager.isRunning, isFalse);
      // A later failure must not start a fallback once an ad has played.
      expect(manager.onPlaybackError(error('AD_PLAYER_ERROR')), isFalse);
      expect(requested, <Uri>[tag(0)]);
    });

    test('cancelling stops the waterfall and ignores later updates', () async {
      manager = build();
      manager.start(configuration(vastTags: <Uri>[tag(1)]));
      await pumpEventQueue();

      manager.cancel();
      expect(manager.isRunning, isFalse);
      expect(manager.currentIndex, -1);

      // A late native error for the cancelled request is a no-op.
      expect(manager.onTagNoFill(error('VAST_EMPTY_RESPONSE')), isFalse);
      expect(requested, <Uri>[tag(0)]);
    });

    test('starting twice cancels the previous run', () async {
      manager = build();
      manager.start(configuration(vastTags: <Uri>[tag(1)]));
      await pumpEventQueue();
      manager.start(configuration(vastTags: <Uri>[tag(2)]));
      await pumpEventQueue();

      expect(requested, <Uri>[tag(0), tag(0)]);
      expect(manager.totalTags, 2);
    });

    test('snapshot reports each tag state after failures', () async {
      manager = build();
      manager.start(configuration(vastTags: <Uri>[tag(1)]));
      await pumpEventQueue();
      manager.onTagNoFill(error('VAST_EMPTY_RESPONSE'));
      await pumpEventQueue();

      final snapshot = manager.snapshot;
      expect(snapshot, hasLength(2));
      expect(snapshot[0].index, 0);
      expect(snapshot[0].state, NativeVideoPlayerAdWaterfallTagState.noFill);
      expect(snapshot[0].error?.code, 'VAST_EMPTY_RESPONSE');
      expect(
        snapshot[1].state,
        NativeVideoPlayerAdWaterfallTagState.requesting,
      );
    });
  });

  group('no-fill classification', () {
    test('IMA no-fill codes continue the waterfall', () {
      for (final code in <String>[
        'VAST_EMPTY_RESPONSE',
        'VAST_NO_ADS_AFTER_WRAPPER',
        'VAST_MEDIA_LOAD_TIMEOUT',
        'AD_BREAK_FETCH_ERROR',
      ]) {
        expect(
          NativeVideoPlayerAdWaterfallManager.isNoFillError(
            NativeVideoPlayerAdError(code: code, message: 'n/a'),
          ),
          isTrue,
          reason: '$code must be treated as no fill',
        );
      }
    });

    test('a no-ads message is no fill even with an unknown code', () {
      expect(
        NativeVideoPlayerAdWaterfallManager.isNoFillError(
          const NativeVideoPlayerAdError(
            code: 'IMA_AD_ERROR',
            message: 'The VAST response is empty and contains no ads.',
          ),
        ),
        isTrue,
      );
    });

    test('a schema error is not treated as no fill', () {
      expect(
        NativeVideoPlayerAdWaterfallManager.isNoFillError(
          const NativeVideoPlayerAdError(
            code: 'VAST_SCHEMA_VALIDATION_ERROR',
            message: 'The VAST document did not validate.',
          ),
        ),
        isFalse,
      );
    });
  });
}
