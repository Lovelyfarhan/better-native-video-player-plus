import 'package:better_native_video_player_plus/better_native_video_player_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// State-machine coverage for the optional advertising subsystem: every
/// session phase must be distinguishable, transitions must follow the
/// documented content/ad lifecycle, invalid events must be rejected, and the
/// content player's activity state must remain the authority the session
/// returns to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');
  const controllerId = 951;
  const platformViewId = 952;
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

  Future<void> loadWithAds({bool resumeContentOnError = true}) async {
    await controller.load(
      url: 'https://content.example.com/video.m3u8',
      adConfiguration: NativeVideoPlayerAdConfiguration(
        adTagUrl: Uri.parse('https://ads.example.com/vast'),
        resumeContentOnError: resumeContentOnError,
      ),
    );
  }

  setUp(() {
    methodCalls.clear();
    installMocks();
    controller = NativeVideoPlayerController(id: controllerId);
  });

  tearDown(() async {
    await controller.dispose();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  group('advertisement state machine', () {
    testWidgets(
      'CONTENT_PLAYING -> AD_LOADING -> AD_PLAYING -> CONTENT_PLAYING',
      (tester) async {
        await attach(tester);
        await loadWithAds();

        final adController = controller.advertisementController;
        final playbackStates = <NativeVideoPlayerAdPlaybackState>[];
        adController.stateStream.listen(playbackStates.add);

        adController.debugHandleContentActivityStateChanged(
          PlayerActivityState.playing,
        );
        expect(
          adController.sessionState,
          NativeVideoPlayerAdSessionState.contentPlaying,
        );

        // Google IMA reports AD_BREAK_STARTED before the first STARTED.
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
            'adEventType': 'breakStarted',
          }),
          isTrue,
        );
        expect(
          adController.sessionState,
          NativeVideoPlayerAdSessionState.adPlaying,
        );
        expect(
          adController.debugHandlePlatformEvent(<String, Object>{
            'adEventType': 'adStarted',
          }),
          isTrue,
        );
        expect(adController.state, NativeVideoPlayerAdPlaybackState.playing);

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
        expect(adController.currentBreak, isNull);

        await tester.pump();
        expect(playbackStates, <NativeVideoPlayerAdPlaybackState>[
          NativeVideoPlayerAdPlaybackState.requesting,
          NativeVideoPlayerAdPlaybackState.playing,
          NativeVideoPlayerAdPlaybackState.idle,
        ]);
      },
    );

    testWidgets(
      'CONTENT_PLAYING -> AD_LOADING -> AD_ERROR -> CONTENT_PLAYING',
      (tester) async {
        await attach(tester);
        await loadWithAds();

        final adController = controller.advertisementController;
        final playbackStates = <NativeVideoPlayerAdPlaybackState>[];
        adController.stateStream.listen(playbackStates.add);

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
            'error': <String, Object>{
              'code': 'VAST_SCHEMA',
              'message': 'Malformed VAST response.',
            },
          }),
          isTrue,
        );

        // Default policy: the failure hands orchestration straight back to
        // the content state — playback is not left broken.
        expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
        expect(
          adController.sessionState,
          NativeVideoPlayerAdSessionState.contentPlaying,
        );
        expect(adController.lastError?.code, 'VAST_SCHEMA');
        expect(adController.currentBreak, isNull);

        await tester.pump();
        expect(playbackStates, <NativeVideoPlayerAdPlaybackState>[
          NativeVideoPlayerAdPlaybackState.requesting,
          NativeVideoPlayerAdPlaybackState.error,
          NativeVideoPlayerAdPlaybackState.idle,
        ]);
      },
    );

    testWidgets('paused advertisements resume and complete', (tester) async {
      await attach(tester);
      await loadWithAds();

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
          'adEventType': 'adStarted',
        }),
        isTrue,
      );

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'adPaused',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adPaused,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.paused);

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'adResumed',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adPlaying,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.playing);

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
      expect(adController.state, NativeVideoPlayerAdPlaybackState.completed);

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
    });

    testWidgets('skipped advertisements end the break', (tester) async {
      await attach(tester);
      await loadWithAds();

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
          'adEventType': 'adStarted',
        }),
        isTrue,
      );

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'adSkipped',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adSkipped,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.skipped);

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
    });

    testWidgets('allAdsCompleted is a valid terminal transition', (
      tester,
    ) async {
      await attach(tester);
      await loadWithAds();

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
          'adEventType': 'adStarted',
        }),
        isTrue,
      );
      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'allAdsCompleted',
        }),
        isTrue,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentPlaying,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
    });

    testWidgets('content authority survives an ad cycle while paused', (
      tester,
    ) async {
      await attach(tester);
      await loadWithAds();

      final adController = controller.advertisementController;
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.paused,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentPaused,
      );

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'requestStarted',
        }),
        isTrue,
      );
      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'adStarted',
        }),
        isTrue,
      );

      // A content-state change during the ad phase is recorded but must not
      // replace the ad session state.
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.paused,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adPlaying,
      );
      expect(adController.contentActivityState, PlayerActivityState.paused);

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'breakCompleted',
        }),
        isTrue,
      );
      // The session returns to the PAUSED content phase, not to playing.
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentPaused,
      );
    });

    testWidgets('an ad error restores the paused content phase', (
      tester,
    ) async {
      await attach(tester);
      await loadWithAds();

      final adController = controller.advertisementController;
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.paused,
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
          'error': <String, Object>{'code': 'net', 'message': 'Offline'},
        }),
        isTrue,
      );

      expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentPaused,
      );
    });

    testWidgets(
      'an explicitly configured ad failure stays failed for app recovery',
      (tester) async {
        await attach(tester);
        await loadWithAds(resumeContentOnError: false);

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
            'adEventType': 'adStarted',
            'adBreak': <String, Object>{'id': 'pre-roll', 'type': 'preRoll'},
          }),
          isTrue,
        );
        expect(
          adController.debugHandlePlatformEvent(<String, Object>{
            'adEventType': 'error',
            'error': <String, Object>{
              'code': 'AD_PLAYER_ERROR',
              'message': 'The ad media failed.',
            },
          }),
          isTrue,
        );

        // Opted-out of automatic resume: the failure stays visible to the
        // app's own recovery flow (the content player itself is unaffected).
        expect(adController.state, NativeVideoPlayerAdPlaybackState.error);
        expect(
          adController.sessionState,
          NativeVideoPlayerAdSessionState.adFailed,
        );
        expect(adController.currentBreak?.id, 'pre-roll');
        expect(adController.lastError?.code, 'AD_PLAYER_ERROR');
      },
    );

    testWidgets('errors without an active ad session are rejected', (
      tester,
    ) async {
      await attach(tester);
      await loadWithAds();

      final adController = controller.advertisementController;
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.playing,
      );

      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'error',
          'error': <String, Object>{'code': 'early', 'message': 'Too early'},
        }),
        isFalse,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentPlaying,
      );
      expect(adController.lastError, isNull);
    });

    testWidgets('initialization failures recover from content phases', (
      tester,
    ) async {
      await attach(tester);
      await loadWithAds();

      final adController = controller.advertisementController;
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.loaded,
      );
      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'error',
          'error': <String, Object>{
            'code': 'IMA_NOT_INITIALIZED',
            'message': 'IMA failed to initialize',
          },
        }),
        isTrue,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentLoaded,
      );
    });

    testWidgets('fatal initialization failures remain failed', (tester) async {
      await attach(tester);
      await loadWithAds(resumeContentOnError: false);

      final adController = controller.advertisementController;
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.loaded,
      );
      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'error',
          'error': <String, Object>{
            'code': 'IMA_NOT_INITIALIZED',
            'message': 'IMA failed to initialize',
          },
        }),
        isTrue,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.error);
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.adFailed,
      );
    });

    testWidgets('disposing during an advertisement stops the ad state machine', (
      tester,
    ) async {
      await attach(tester);
      await loadWithAds();

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
          'adEventType': 'adStarted',
        }),
        isTrue,
      );

      await adController.dispose();

      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.disposed,
      );
      expect(
        adController.debugHandlePlatformEvent(<String, Object>{
          'adEventType': 'allAdsCompleted',
        }),
        isFalse,
      );
    });

    testWidgets('content completion remains authoritative outside an ad', (
      tester,
    ) async {
      await attach(tester);
      await loadWithAds();

      final adController = controller.advertisementController;
      adController.debugHandleContentActivityStateChanged(
        PlayerActivityState.completed,
      );

      expect(
        adController.contentActivityState,
        PlayerActivityState.completed,
      );
      expect(
        adController.sessionState,
        NativeVideoPlayerAdSessionState.contentCompleted,
      );
      expect(adController.state, NativeVideoPlayerAdPlaybackState.idle);
    });

    testWidgets(
      'envelope-shaped events decode while no transport is attached',
      (tester) async {
        await attach(tester);
        await loadWithAds();

        final adController = controller.advertisementController;
        // releaseResources() detaches the per-view transport; the
        // controller-level event channel (and thus envelope-shaped ad
        // events) keeps working across it.
        await controller.releaseResources();

        adController.debugHandleContentActivityStateChanged(
          PlayerActivityState.playing,
        );
        expect(
          adController.debugHandlePlatformEvent(<String, Object>{
            'event': 'advertisement',
            'adEvent': <String, Object>{'adEventType': 'requestStarted'},
          }),
          isTrue,
        );
        expect(
          adController.sessionState,
          NativeVideoPlayerAdSessionState.adLoading,
        );
        expect(adController.state, NativeVideoPlayerAdPlaybackState.requesting);
      },
    );
  });
}
