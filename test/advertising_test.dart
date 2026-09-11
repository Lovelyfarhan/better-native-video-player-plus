import 'package:better_native_video_player_plus/better_native_video_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');
  const controllerId = 941;
  const platformViewId = 942;
  final methodCalls = <MethodCall>[];

  late NativeVideoPlayerController controller;

  void installMocks() {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      methodCalls.add(call);
      switch (call.method) {
        case 'getAvailableQualities':
          return <Object>[];
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_$controllerId'),
      MockStreamHandler.inline(onListen: (_, arguments) {}),
    );
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_$platformViewId'),
      MockStreamHandler.inline(onListen: (_, arguments) {}),
    );
  }

  Future<void> attach(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await controller.onPlatformViewCreated(
      platformViewId,
      tester.element(find.byType(SizedBox)),
    );
    await controller.initialize();
    await tester.pump(const Duration(milliseconds: 100));
  }

  setUp(() {
    methodCalls.clear();
    installMocks();
    controller = NativeVideoPlayerController(id: controllerId, autoPlay: true);
  });

  tearDown(() async {
    await controller.dispose();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('configuration serializes VAST/VMAP schedule data', () {
    final configuration = NativeVideoPlayerAdConfiguration(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
      tagType: NativeVideoPlayerAdTagType.vast,
      adBreaks: <NativeVideoPlayerAdBreak>[
        const NativeVideoPlayerAdBreak(
          id: 'pre-roll',
          type: NativeVideoPlayerAdBreakType.preRoll,
        ),
        const NativeVideoPlayerAdBreak(
          id: 'mid-roll-1',
          type: NativeVideoPlayerAdBreakType.midRoll,
          position: Duration(minutes: 5),
        ),
        const NativeVideoPlayerAdBreak.midRoll(
          id: 'mid-roll-2',
          position: Duration(minutes: 12),
        ),
        const NativeVideoPlayerAdBreak(
          id: 'post-roll',
          type: NativeVideoPlayerAdBreakType.postRoll,
        ),
      ],
    );

    expect(configuration.toMap(), <String, Object>{
      'adTagUrl': 'https://ads.example.com/vast',
      'tagType': 'vast',
      'adBreaks': <Map<String, Object>>[
        <String, Object>{'id': 'pre-roll', 'type': 'preRoll'},
        <String, Object>{
          'id': 'mid-roll-1',
          'type': 'midRoll',
          'positionMs': const Duration(minutes: 5).inMilliseconds,
        },
        <String, Object>{
          'id': 'mid-roll-2',
          'type': 'midRoll',
          'positionMs': const Duration(minutes: 12).inMilliseconds,
        },
        <String, Object>{'id': 'post-roll', 'type': 'postRoll'},
      ],
    });
    expect(configuration.preRollBreaks.single.id, 'pre-roll');
    expect(
      configuration.midRollBreaks.map((breakInfo) => breakInfo.id),
      <String>['mid-roll-1', 'mid-roll-2'],
    );
    expect(configuration.postRollBreaks.single.id, 'post-roll');
  });

  test(
    'typed configuration supports disabled VMAP, timeout, skip, and metadata',
    () {
      final configuration = NativeVideoPlayerAdConfiguration.vmap(
        adTagUrl: Uri.parse('https://ads.example.com/vmap'),
        enabled: false,
        timeout: const Duration(seconds: 8),
        skipConfiguration: const NativeVideoPlayerAdSkipConfiguration(
          allowUserSkip: false,
          skipAfter: Duration(seconds: 5),
        ),
        requestMetadata: NativeVideoPlayerAdRequestMetadata(
          contentId: 'episode-42',
          contentTitle: 'Episode 42',
          contentUrl: Uri.parse('https://content.example.com/episode-42'),
          customParameters: const <String, String>{'category': 'drama'},
        ),
        adBreaks: const <NativeVideoPlayerAdBreak>[
          NativeVideoPlayerAdBreak.preRoll(id: 'pre-roll'),
          NativeVideoPlayerAdBreak.postRoll(id: 'post-roll'),
        ],
      );

      expect(configuration.tagType, NativeVideoPlayerAdTagType.vmap);
      expect(configuration.enabled, isFalse);
      expect(configuration.timeout, const Duration(seconds: 8));
      expect(configuration.toMap(), <String, Object>{
        'adTagUrl': 'https://ads.example.com/vmap',
        'tagType': 'vmap',
        'enabled': false,
        'adBreaks': <Map<String, Object>>[
          <String, Object>{'id': 'pre-roll', 'type': 'preRoll'},
          <String, Object>{'id': 'post-roll', 'type': 'postRoll'},
        ],
        'timeoutMs': 8000,
        'skipConfiguration': <String, Object>{
          'allowUserSkip': false,
          'skipAfterMs': 5000,
        },
        'requestMetadata': <String, Object>{
          'contentId': 'episode-42',
          'contentTitle': 'Episode 42',
          'contentUrl': 'https://content.example.com/episode-42',
          'customParameters': <String, String>{'category': 'drama'},
        },
      });
    },
  );

  testWidgets('an unconfigured load preserves the existing native payload', (
    tester,
  ) async {
    await attach(tester);
    await controller.load(url: 'https://content.example.com/video.m3u8');

    final load = methodCalls.lastWhere((call) => call.method == 'load');
    final arguments = Map<dynamic, dynamic>.from(load.arguments as Map);
    expect(arguments.containsKey('adConfiguration'), isFalse);
    expect(controller.advertisementController.isEnabled, isFalse);
    expect(
      controller.advertisementController.state,
      NativeVideoPlayerAdPlaybackState.disabled,
    );
  });

  testWidgets('post-roll starts once at content completion', (tester) async {
    await attach(tester);
    final configuration = NativeVideoPlayerAdConfiguration.vast(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
      adBreaks: const <NativeVideoPlayerAdBreak>[
        NativeVideoPlayerAdBreak.postRoll(id: 'post-roll'),
      ],
    );
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );

    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 30),
      activityState: PlayerActivityState.completed,
    );
    await tester.pump();
    expect(
      methodCalls.map((call) => call.method),
      containsAllInOrder(<String>[
        'load',
        'advertisementInitialize',
        'advertisementRequestAds',
        'advertisementContentComplete',
      ]),
    );

    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{'adEventType': 'adStarted'},
    });
    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{'adEventType': 'allAdsCompleted'},
    });
    expect(
      controller.advertisementController.sessionState,
      NativeVideoPlayerAdSessionState.contentCompleted,
    );

    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 30),
      activityState: PlayerActivityState.completed,
    );
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'advertisementInitialize'),
      hasLength(1),
    );
  });

  testWidgets('replaying after post-roll creates a fresh ad session', (
    tester,
  ) async {
    await attach(tester);
    final configuration = NativeVideoPlayerAdConfiguration.vast(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
      adBreaks: const <NativeVideoPlayerAdBreak>[
        NativeVideoPlayerAdBreak.postRoll(id: 'post-roll'),
      ],
    );
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );
    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 30),
      activityState: PlayerActivityState.completed,
    );
    await tester.pump();
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
      force: true,
    );
    controller.debugUpdatePlaybackState(
      position: Duration.zero,
      activityState: PlayerActivityState.playing,
    );
    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 30),
      activityState: PlayerActivityState.completed,
    );
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'advertisementInitialize'),
      hasLength(2),
    );
  });

  testWidgets('post-roll failure completes playback normally', (tester) async {
    await attach(tester);
    final configuration = NativeVideoPlayerAdConfiguration.vast(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
      adBreaks: const <NativeVideoPlayerAdBreak>[
        NativeVideoPlayerAdBreak.postRoll(id: 'post-roll'),
      ],
    );
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );
    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 30),
      activityState: PlayerActivityState.completed,
    );
    await tester.pump();
    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{
        'adEventType': 'error',
        'error': <String, Object>{'code': 'network', 'message': 'offline'},
      },
    });
    expect(
      controller.advertisementController.sessionState,
      NativeVideoPlayerAdSessionState.contentCompleted,
    );
  });

  testWidgets('VMAP owns scheduling and ignores manual break positions', (
    tester,
  ) async {
    await attach(tester);
    final configuration = NativeVideoPlayerAdConfiguration.vmap(
      adTagUrl: Uri.parse('https://ads.example.com/vmap'),
      adBreaks: const <NativeVideoPlayerAdBreak>[
        NativeVideoPlayerAdBreak.preRoll(id: 'manual-pre'),
        NativeVideoPlayerAdBreak.midRoll(
          id: 'manual-mid',
          position: Duration(minutes: 10),
        ),
        NativeVideoPlayerAdBreak.postRoll(id: 'manual-post'),
      ],
    );
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );
    await tester.pump();

    expect(
      methodCalls.map((call) => call.method),
      containsAllInOrder(<String>[
        'load',
        'advertisementInitialize',
        'advertisementRequestAds',
      ]),
    );
    final load = methodCalls.firstWhere((call) => call.method == 'load');
    expect(
      (Map<dynamic, dynamic>.from(load.arguments as Map))['autoPlay'],
      isFalse,
    );

    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 10),
      activityState: PlayerActivityState.playing,
    );
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'advertisementInitialize'),
      hasLength(1),
    );
  });

  testWidgets('invalid VMAP still reports native ad errors', (tester) async {
    await attach(tester);
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration.vmap(
        adTagUrl: Uri.parse('https://ads.example.com/malformed-vmap'),
      ),
    );
    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{'adEventType': 'requestStarted'},
    });
    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{'adEventType': 'adStarted'},
    });
    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{'adEventType': 'adStarted'},
    });
    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{
        'adEventType': 'error',
        'error': <String, Object>{
          'code': 'VAST_SCHEMA',
          'message': 'Malformed VMAP response.',
        },
      },
    });
    expect(controller.advertisementController.lastError?.code, 'VAST_SCHEMA');
  });

  testWidgets('normalized ad events include request metadata context', (
    tester,
  ) async {
    await attach(tester);
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration.vast(
        adTagUrl: Uri.parse('https://ads.example.com/vast'),
        requestMetadata: NativeVideoPlayerAdRequestMetadata(
          contentId: 'content-1',
          contentTitle: 'Content 1',
          contentUrl: Uri.parse('https://content.example.com/video.m3u8'),
        ),
      ),
    );

    final events = <NativeVideoPlayerAdEvent>[];
    controller.advertisementController.events.listen(events.add);
    controller.advertisementController.debugHandlePlatformEvent(
      <String, Object>{'adEventType': 'requestStarted'},
    );
    await tester.pump();

    expect(events.single.contentId, 'content-1');
    expect(events.single.contentTitle, 'Content 1');
    expect(
      events.single.contentUrl,
      Uri.parse('https://content.example.com/video.m3u8'),
    );
    expect(events.single.timestamp, isNotNull);
  });

  testWidgets('releasing resources destroys native advertisement resources', (
    tester,
  ) async {
    await attach(tester);
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration.vast(
        adTagUrl: Uri.parse('https://ads.example.com/vast'),
        adBreaks: const <NativeVideoPlayerAdBreak>[
          NativeVideoPlayerAdBreak.preRoll(id: 'pre-roll'),
        ],
      ),
    );
    await controller.releaseResources();

    expect(
      methodCalls.map((call) => call.method),
      contains('advertisementDestroy'),
    );
    expect(controller.advertisementController.isEnabled, isTrue);
  });

  testWidgets('ad overlay respects IMA skip offset and non-skippable ads', (
    tester,
  ) async {
    await attach(tester);
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration.vast(
        adTagUrl: Uri.parse('https://ads.example.com/vast'),
        adBreaks: const <NativeVideoPlayerAdBreak>[
          NativeVideoPlayerAdBreak.preRoll(id: 'pre-roll'),
        ],
      ),
    );

    controller.advertisementController.debugHandlePlatformEvent(
      <String, Object>{'adEventType': 'requestStarted'},
    );
    controller.advertisementController.debugHandlePlatformEvent(
      <String, Object>{'adEventType': 'adStarted'},
    );
    controller.advertisementController.debugHandlePlatformEvent(
      <String, Object>{
        'adEventType': 'adProgress',
        'positionMs': 1000,
        'durationMs': 10000,
        'metadata': <String, Object>{
          'isSkippable': true,
          'skipTimeOffsetMs': 5000,
        },
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 180,
          child: NativeVideoPlayerAdOverlay(controller: controller),
        ),
      ),
    );
    expect(find.text('Skip in 4'), findsOneWidget);
    expect(find.text('Skip Ad'), findsNothing);

    controller.advertisementController.debugHandlePlatformEvent(
      <String, Object>{
        'adEventType': 'adProgress',
        'positionMs': 5000,
        'durationMs': 10000,
        'metadata': <String, Object>{
          'isSkippable': true,
          'skipTimeOffsetMs': 5000,
        },
      },
    );
    await tester.pump();
    expect(find.text('Skip Ad'), findsOneWidget);

    controller.advertisementController.debugHandlePlatformEvent(
      <String, Object>{
        'adEventType': 'adProgress',
        'positionMs': 5000,
        'durationMs': 10000,
        'metadata': <String, Object>{'isSkippable': false},
      },
    );
    await tester.pump();
    expect(find.text('Skip Ad'), findsNothing);
    expect(find.textContaining('Skip in'), findsNothing);
  });

  testWidgets('a configured load forwards only the optional ad contract', (
    tester,
  ) async {
    await attach(tester);
    final configuration = NativeVideoPlayerAdConfiguration(
      adTagUrl: Uri.parse('https://ads.example.com/vmap'),
      tagType: NativeVideoPlayerAdTagType.vmap,
    );

    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );

    final load = methodCalls.lastWhere((call) => call.method == 'load');
    final arguments = Map<dynamic, dynamic>.from(load.arguments as Map);
    expect(arguments['adConfiguration'], configuration.toMap());
    expect(controller.advertisementController.isEnabled, isTrue);
    expect(
      controller.advertisementController.state,
      NativeVideoPlayerAdPlaybackState.idle,
    );
  });

  testWidgets('a pre-roll defers content autoplay and requests ads', (
    tester,
  ) async {
    await attach(tester);

    final configuration = NativeVideoPlayerAdConfiguration.vast(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
      adBreaks: const <NativeVideoPlayerAdBreak>[
        NativeVideoPlayerAdBreak.preRoll(id: 'pre-roll'),
      ],
    );

    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );

    final load = methodCalls.firstWhere((call) => call.method == 'load');
    final loadArguments = Map<dynamic, dynamic>.from(load.arguments as Map);
    expect(loadArguments['autoPlay'], isFalse);
    expect(
      methodCalls.map((call) => call.method),
      containsAllInOrder(<String>[
        'load',
        'advertisementInitialize',
        'advertisementRequestAds',
      ]),
    );
  });

  testWidgets('multiple mid-rolls trigger once and restore saved positions', (
    tester,
  ) async {
    await attach(tester);
    final configuration = NativeVideoPlayerAdConfiguration.vast(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
      adBreaks: const <NativeVideoPlayerAdBreak>[
        NativeVideoPlayerAdBreak.midRoll(
          id: 'mid-10',
          position: Duration(minutes: 10),
        ),
        NativeVideoPlayerAdBreak.midRoll(
          id: 'mid-20',
          position: Duration(minutes: 20),
        ),
      ],
    );
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );

    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 10),
      activityState: PlayerActivityState.playing,
    );
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'advertisementInitialize'),
      hasLength(1),
    );

    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{'adEventType': 'adStarted'},
    });
    controller.debugHandleControllerEvent(<String, Object>{
      'event': 'advertisement',
      'adEvent': <String, Object>{'adEventType': 'allAdsCompleted'},
    });
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'seekTo').last.arguments,
      <String, Object>{
        'viewId': platformViewId,
        'milliseconds': const Duration(minutes: 10).inMilliseconds,
      },
    );

    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 9, seconds: 30),
      activityState: PlayerActivityState.playing,
    );
    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 10, seconds: 1),
      activityState: PlayerActivityState.playing,
    );
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'advertisementInitialize'),
      hasLength(1),
    );

    controller.debugUpdatePlaybackState(
      position: const Duration(minutes: 20),
      activityState: PlayerActivityState.playing,
    );
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'advertisementInitialize'),
      hasLength(2),
    );
  });

  testWidgets('a disabled configuration stays disabled without changing load', (
    tester,
  ) async {
    await attach(tester);
    final configuration = NativeVideoPlayerAdConfiguration.vast(
      adTagUrl: Uri.parse('https://ads.example.com/vast'),
      enabled: false,
    );

    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: configuration,
    );

    final load = methodCalls.lastWhere((call) => call.method == 'load');
    final arguments = Map<dynamic, dynamic>.from(load.arguments as Map);
    expect(arguments['adConfiguration'], configuration.toMap());
    expect(controller.advertisementController.configuration, configuration);
    expect(controller.advertisementController.isEnabled, isFalse);
    expect(
      controller.advertisementController.state,
      NativeVideoPlayerAdPlaybackState.disabled,
    );
  });

  testWidgets('ad lifecycle events retain pod metadata and surface errors', (
    tester,
  ) async {
    await attach(tester);
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration(
        adTagUrl: Uri.parse('https://ads.example.com/vast'),
        resumeContentOnError: false,
      ),
    );

    final adController = controller.advertisementController;
    final events = <NativeVideoPlayerAdEvent>[];
    final errors = <NativeVideoPlayerAdError>[];
    adController.events.listen(events.add);
    adController.errors.listen(errors.add);

    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'requestStarted',
      }),
      isTrue,
    );
    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'adStarted',
        'adBreak': <String, Object>{
          'id': 'mid-roll-1',
          'type': 'midRoll',
          'positionMs': 120000,
        },
        'adPositionInPod': 2,
        'totalAdsInPod': 3,
        'metadata': <String, Object>{
          'adId': 'ad-2',
          'creativeId': 'creative-2',
          'title': 'Trailer',
          'durationMs': 30000,
        },
      }),
      isTrue,
    );
    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'error',
        'error': <String, Object>{
          'code': 'ad-request-failed',
          'message': 'The ad tag could not be loaded.',
        },
      }),
      isTrue,
    );
    await tester.pump();

    expect(adController.state, NativeVideoPlayerAdPlaybackState.error);
    expect(adController.currentBreak?.id, 'mid-roll-1');
    expect(events, hasLength(3));
    expect(events[1].adBreakId, 'mid-roll-1');
    expect(events[1].adPositionInPod, 2);
    expect(events[1].totalAdsInPod, 3);
    expect(events[1].metadata?.adId, 'ad-2');
    expect(events[1].metadata?.duration, const Duration(seconds: 30));
    expect(errors.single.code, 'ad-request-failed');
  });

  testWidgets(
    'ad state transitions return to the authoritative content state',
    (tester) async {
      await attach(tester);
      await controller.load(
        url: 'https://content.example.com/video.m3u8',
        adConfiguration: NativeVideoPlayerAdConfiguration(
          adTagUrl: Uri.parse('https://ads.example.com/vast'),
        ),
      );

      final adController = controller.advertisementController;
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.playing,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentPlaying,
      );

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'requestStarted',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adLoading,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.requesting);

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'adStarted',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adPlaying,
      );

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'adCompleted',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adCompleted,
      );
      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'breakCompleted',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentPlaying,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
      expect(adController.contentActivityState, PlayerActivityState.playing);
    },
  );

  testWidgets('an ad failure resumes content by default', (tester) async {
    await attach(tester);
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration(
        adTagUrl: Uri.parse('https://ads.example.com/vast'),
      ),
    );

    final adController = controller.advertisementController;
    adController.debugHandleContentActivityStateChanged(
      PlayerActivityState.playing,
    );
    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'requestStarted',
      }),
      isTrue,
    );
    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'error',
        'error': <String, Object>{'code': 'network', 'message': 'Timed out'},
      }),
      isTrue,
    );

    expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
    expect(
      adController.sessionState,
      NativeVideoPlayerAdSessionState.contentPlaying,
    );
    expect(adController.lastError?.code, 'network');
  });

  testWidgets('invalid advertisement transitions are ignored', (tester) async {
    await attach(tester);
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration(
        adTagUrl: Uri.parse('https://ads.example.com/vast'),
      ),
    );

    final adController = controller.advertisementController;
    adController.debugHandleContentActivityStateChanged(
      PlayerActivityState.playing,
    );

    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'adStarted',
      }),
      isFalse,
    );
    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'adPaused',
      }),
      isFalse,
    );
    expect(
      adController.debugHandlePlatformEvent(<String, Object>{
        'adEventType': 'breakCompleted',
      }),
      isFalse,
    );
    expect(
      adController.sessionState,
      NativeVideoPlayerAdSessionState.contentPlaying,
    );
    expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
  });
}
