part of 'native_video_player_controller.dart';

/// Controller-owned lifecycle and event surface for optional in-stream ads.
///
/// This class coordinates the provider-neutral ad lifecycle around the native
/// IMA adapter. When no ad
/// configuration is supplied it remains [isEnabled] false and sends no
/// additional platform commands.
class NativeVideoPlayerAdvertisementController {
  NativeVideoPlayerAdConfiguration? _configuration;
  NativeVideoPlayerAdvertisementPlatform? _platform;
  NativeVideoPlayerAdPlaybackState _state =
      NativeVideoPlayerAdPlaybackState.disabled;
  NativeVideoPlayerAdSessionState _sessionState =
      NativeVideoPlayerAdSessionState.contentIdle;
  PlayerActivityState _contentActivityState = PlayerActivityState.idle;
  NativeVideoPlayerAdBreak? _currentBreak;
  NativeVideoPlayerAdError? _lastError;
  NativeVideoPlayerAdEvent? _lastEvent;
  bool _isDisposed = false;

  /// Drives ordered VAST-tag fallback for the active break, when the
  /// configuration supplies more than one tag.
  NativeVideoPlayerAdWaterfallManager? _waterfall;
  StreamSubscription<NativeVideoPlayerAdEvent>? _waterfallEventSubscription;

  /// The break whose tags are currently being requested through [_waterfall].
  NativeVideoPlayerAdBreak? _waterfallBreak;

  final StreamController<NativeVideoPlayerAdPlaybackState> _stateController =
      StreamController<NativeVideoPlayerAdPlaybackState>.broadcast();
  final StreamController<NativeVideoPlayerAdSessionState>
  _sessionStateController =
      StreamController<NativeVideoPlayerAdSessionState>.broadcast();
  final StreamController<NativeVideoPlayerAdEvent> _eventController =
      StreamController<NativeVideoPlayerAdEvent>.broadcast();
  final StreamController<NativeVideoPlayerAdError> _errorController =
      StreamController<NativeVideoPlayerAdError>.broadcast();

  /// Configuration associated with the current content load, if any.
  NativeVideoPlayerAdConfiguration? get configuration => _configuration;

  /// Whether advertising is configured for the current content load.
  bool get isEnabled => _configuration?.enabled ?? false;

  /// Current advertisement playback state.
  NativeVideoPlayerAdPlaybackState get state => _state;

  /// Current content/ad orchestration phase. This never controls the content
  /// engine; content variants are derived from [contentActivityState].
  /// Current content/ad session phase.
  NativeVideoPlayerAdSessionState get sessionState => _sessionState;

  /// Latest content activity state from [NativeVideoPlayerController].
  ///
  /// It remains current while an ad phase is active, allowing a future native
  /// adapter to pause/resume the existing player without becoming a second
  /// content state authority.
  PlayerActivityState get contentActivityState => _contentActivityState;

  /// The break currently being prepared or played, if the platform reported
  /// one. A break can contain an ad pod.
  NativeVideoPlayerAdBreak? get currentBreak => _currentBreak;

  /// Most recent normalized advertisement error.
  NativeVideoPlayerAdError? get lastError => _lastError;

  /// Most recent normalized advertisement event.
  NativeVideoPlayerAdEvent? get lastEvent => _lastEvent;

  /// Emits advertisement playback state changes.
  Stream<NativeVideoPlayerAdPlaybackState> get stateStream =>
      _stateController.stream;

  /// Emits content/ad session phase changes.
  Stream<NativeVideoPlayerAdSessionState> get sessionStateStream =>
      _sessionStateController.stream;

  /// Emits normalized advertisement events.
  Stream<NativeVideoPlayerAdEvent> get events => _eventController.stream;

  /// Emits structured advertisement errors.
  Stream<NativeVideoPlayerAdError> get errors => _errorController.stream;

  /// The active VAST-tag waterfall, or null when the current configuration has
  /// a single tag (or none).
  ///
  /// Applications normally do not need this: the same milestones are emitted
  /// as [NativeVideoPlayerAdEvent]s on [events]. It is exposed for callers that
  /// want to render an "attempt N of M" progress indicator.
  NativeVideoPlayerAdWaterfallManager? get waterfall => _waterfall;

  /// Whether more than one tag is being tried for the current break.
  bool get hasTagWaterfall => _waterfall?.isRunning ?? false;

  /// Zero-based index of the tag currently being requested, or null when no
  /// waterfall is active.
  int? get currentTagIndex => _waterfall?.isRunning == true
      ? _waterfall!.currentIndex
      : null;

  /// Ordered tag list of the active waterfall, or an empty list.
  List<Uri> get currentTags => _waterfall?.snapshot
          .map((tag) => tag.url)
          .toList(growable: false) ??
      const <Uri>[];

  /// Requests the active native ad to skip when IMA permits it.
  Future<void> skipAdvertisement() async {
    await _platform?.skipAdvertisement();
  }

  /// Requests the configured ad schedule for the current content load.
  ///
  /// A single-tag configuration issues exactly one request, preserving the
  /// original behavior. A configuration with more than one tag starts the
  /// VAST waterfall instead: the first tag is requested, and every "no fill"
  /// or timeout advances to the next tag until an ad plays or the list is
  /// exhausted.
  ///
  /// [breakInfo] identifies the break being requested (pre-roll, a mid-roll,
  /// or a post-roll). It is recorded so waterfall events can report which
  /// break they belong to.
  ///
  /// [onRequestIssued] runs once the first tag request has been handed to the
  /// platform. The post-roll path uses it to signal content completion only
  /// after a request is in flight.
  Future<void> requestAdvertisements({
    NativeVideoPlayerAdBreak? breakInfo,
    Future<void> Function()? onRequestIssued,
  }) async {
    if (_isDisposed) {
      return;
    }
    final configuration = _configuration;
    final platform = _platform;
    if (configuration == null || !configuration.enabled || platform == null) {
      return;
    }

    if (!configuration.hasTagWaterfall) {
      // Single-tag path: unchanged from the original implementation.
      await platform.initializeAdvertisement(configuration);
      await platform.requestAdvertisements();
      await onRequestIssued?.call();
      return;
    }

    _waterfallBreak = breakInfo;
    final waterfall = _ensureWaterfall();
    if (!waterfall.start(configuration)) {
      return;
    }
    // The waterfall's requestTag callback performs initialize + request for
    // each tag, so the first request is already in flight here.
    await onRequestIssued?.call();
  }

  /// Builds (or rebuilds) the waterfall and its event bridge.
  NativeVideoPlayerAdWaterfallManager _ensureWaterfall() {
    _waterfallEventSubscription?.cancel();
    _waterfall = NativeVideoPlayerAdWaterfallManager(
      requestTag: (tagConfiguration) async {
        final platform = _platform;
        if (platform == null) {
          return;
        }
        // Re-initializing with the next tag destroys the previous AdsManager
        // inside the native bridge while the AdsLoader is created once per
        // content load and reused for every fallback.
        await platform.initializeAdvertisement(tagConfiguration);
        await platform.requestAdvertisements();
      },
      onTagAbandoned: () async {
        // Best-effort teardown of the failed attempt. A failure here must not
        // stop the waterfall, so it is swallowed by the manager.
        await _platform?.stopAdvertisement();
      },
      continueOnFatalErrors: true,
    );
    _waterfallEventSubscription = _waterfall!.events.listen(
      _handleWaterfallEvent,
    );
    return _waterfall!;
  }

  /// Forwards a waterfall milestone onto the public ad event stream.
  ///
  /// The event is enriched with the break it belongs to and the content
  /// context, then applied to the ad state machine so `tagRequested`
  /// advances to `requesting` and `waterfallExhausted` fails the session.
  void _handleWaterfallEvent(NativeVideoPlayerAdEvent event) {
    if (_isDisposed || _eventController.isClosed) {
      return;
    }
    final requestMetadata = _configuration?.requestMetadata;
    final enriched = event.copyWithContext(
      timestamp: event.timestamp ?? DateTime.now(),
      contentId: event.contentId ?? requestMetadata?.contentId,
      contentTitle: event.contentTitle ?? requestMetadata?.contentTitle,
      contentUrl: event.contentUrl ?? requestMetadata?.contentUrl,
    );

    // Publish to the ad streams first so an application observes the same
    // order an adapter would produce: event, then any state change.
    if (!_eventController.isClosed) {
      _lastEvent = enriched;
      _eventController.add(enriched);
    }
    if (event.error != null && !_errorController.isClosed) {
      _lastError = event.error;
      _errorController.add(event.error!);
    }

    if (_waterfallBreak != null) {
      _currentBreak = _waterfallBreak;
    }
    _applyEventTransition(enriched);
  }

  /// Reports a per-tag error to the waterfall, if one is active.
  ///
  /// Returns true when the waterfall consumed the error and advanced (or
  /// ended) on its own, so the caller must not also treat it as a terminal
  /// ad-session failure.
  bool _reportToWaterfall(NativeVideoPlayerAdError error) {
    final waterfall = _waterfall;
    if (waterfall == null || !waterfall.isRunning) {
      return false;
    }
    // A failure reported before an ad started is a tag-level failure. After
    // playback begins a media error is also per-tag (the creative itself
    // failed), which [onPlaybackError] models.
    waterfall.onPlaybackError(error);
    return true;
  }

  /// Releases the current AdsManager while keeping the AdsLoader reusable.
  Future<void> abandonCurrentTag() async {
    await _platform?.stopAdvertisement();
  }

  /// Associates the current per-view transport with this controller.
  ///
  /// Associates the current per-view native advertising transport.
  void _attachPlatform(NativeVideoPlayerAdvertisementPlatform platform) {
    if (_isDisposed) {
      return;
    }
    _platform = platform;
  }

  /// Removes a transport whose platform view has been released.
  void _detachPlatform() {
    _platform = null;
  }

  /// Called by the owning content controller for every accepted load request.
  ///
  /// It is intentionally library-private: applications configure ads through
  /// [NativeVideoPlayerController.load], so an active content/ad pair cannot
  /// be changed out from under the native player.
  void _configureForContent(
    NativeVideoPlayerAdConfiguration? configuration, {
    required PlayerActivityState contentActivityState,
  }) {
    if (_isDisposed) {
      return;
    }
    _cancelWaterfall();
    _configuration = configuration;
    _contentActivityState = contentActivityState;
    _currentBreak = null;
    _lastError = null;
    _setState(
      configuration == null || !configuration.enabled
          ? NativeVideoPlayerAdPlaybackState.disabled
          : NativeVideoPlayerAdPlaybackState.idle,
    );
    _setSessionState(_contentSessionStateFor(contentActivityState));
  }

  /// Synchronizes the content portion of the state machine from the existing
  /// controller state. During an active ad phase this records the latest
  /// content state but deliberately does not replace the ad session state.
  void _handleContentActivityStateChanged(PlayerActivityState contentState) {
    if (_isDisposed) {
      return;
    }
    _contentActivityState = contentState;

    if (!isEnabled || !_isAdPhase(_sessionState)) {
      _setSessionState(_contentSessionStateFor(contentState));
    }
  }

  /// Handles the reserved controller-level native event envelope.
  ///
  /// Returns false for an invalid transition; invalid events are ignored and
  /// cannot corrupt the current content/ad state. Phase 3 has no native
  /// adapter yet, but keeping validation here makes the future bridge safe.
  ///
  /// The envelope is `{'event': 'advertisement', 'adEvent': {...}}`; a bare
  /// ad-event map decodes directly. Unwrapping here (not only in the attached
  /// transport's decodeEvent) keeps the state machine decodable even while no
  /// per-view transport exists, e.g. after releaseResources().
  bool _handlePlatformEvent(Map<dynamic, dynamic> platformEvent) {
    if (_isDisposed || !isEnabled) {
      return false;
    }
    final Object? adEventPayload = platformEvent['adEvent'];
    var event =
        _platform?.decodeEvent(platformEvent) ??
        NativeVideoPlayerAdEvent.fromMap(
          adEventPayload is Map ? adEventPayload : platformEvent,
        );
    final requestMetadata = _configuration?.requestMetadata;
    event = event.copyWithContext(
      timestamp: event.timestamp ?? DateTime.now(),
      contentId: event.contentId ?? requestMetadata?.contentId,
      contentTitle: event.contentTitle ?? requestMetadata?.contentTitle,
      contentUrl: event.contentUrl ?? requestMetadata?.contentUrl,
    );
    if (!_applyEventTransition(event)) {
      return false;
    }

    if (event.adBreak != null) {
      _currentBreak = event.adBreak;
    }
    if (event.error != null) {
      _lastError = event.error;
      if (!_errorController.isClosed) {
        _errorController.add(event.error!);
      }
    }
    if (!_eventController.isClosed) {
      _lastEvent = event;
      _eventController.add(event);
    }
    return true;
  }

  /// Test-only entry point for validating the future native event contract.
  @visibleForTesting
  bool debugHandlePlatformEvent(Map<dynamic, dynamic> platformEvent) {
    return _handlePlatformEvent(platformEvent);
  }

  /// Test-only entry point for proving that content remains authoritative
  /// while an advertisement session is active.
  @visibleForTesting
  void debugHandleContentActivityStateChanged(
    PlayerActivityState contentState,
  ) {
    _handleContentActivityStateChanged(contentState);
  }

  bool _applyEventTransition(NativeVideoPlayerAdEvent event) {
    switch (event.type) {
      case NativeVideoPlayerAdEventType.tagRequested:
      case NativeVideoPlayerAdEventType.requestStarted:
      case NativeVideoPlayerAdEventType.breakReady:
        if (!_isContentPhase(_sessionState) &&
            _sessionState != NativeVideoPlayerAdSessionState.adLoading) {
          return false;
        }
        _setSessionState(NativeVideoPlayerAdSessionState.adLoading);
        _setState(
          event.type == NativeVideoPlayerAdEventType.requestStarted
              ? NativeVideoPlayerAdPlaybackState.requesting
              : NativeVideoPlayerAdPlaybackState.ready,
        );
        return true;

      case NativeVideoPlayerAdEventType.breakStarted:
      case NativeVideoPlayerAdEventType.adResumed:
        final canStart =
            _sessionState == NativeVideoPlayerAdSessionState.adLoading ||
            _sessionState == NativeVideoPlayerAdSessionState.adPaused ||
            _sessionState == NativeVideoPlayerAdSessionState.adCompleted ||
            _sessionState == NativeVideoPlayerAdSessionState.contentCompleted;
        if (!canStart) {
          return false;
        }
        _setSessionState(NativeVideoPlayerAdSessionState.adPlaying);
        _setState(NativeVideoPlayerAdPlaybackState.playing);
        return true;

      case NativeVideoPlayerAdEventType.adStarted:
        // Google IMA reports AD_BREAK_STARTED before STARTED. The latter is
        // therefore a valid, idempotent transition while the break is already
        // playing; it must not be mistaken for a corrupt event sequence.
        final canStart =
            _sessionState == NativeVideoPlayerAdSessionState.adLoading ||
            _sessionState == NativeVideoPlayerAdSessionState.adPlaying ||
            _sessionState == NativeVideoPlayerAdSessionState.adPaused ||
            _sessionState == NativeVideoPlayerAdSessionState.adCompleted ||
            _sessionState == NativeVideoPlayerAdSessionState.contentCompleted;
        if (!canStart) {
          return false;
        }
        // The waterfall is resolved the moment an ad actually starts: a later
        // failure is a normal ad-session failure, not a fallback trigger.
        _waterfall?.onAdStarted();
        _setSessionState(NativeVideoPlayerAdSessionState.adPlaying);
        _setState(NativeVideoPlayerAdPlaybackState.playing);
        return true;

      case NativeVideoPlayerAdEventType.adPaused:
        if (_sessionState != NativeVideoPlayerAdSessionState.adPlaying) {
          return false;
        }
        _setSessionState(NativeVideoPlayerAdSessionState.adPaused);
        _setState(NativeVideoPlayerAdPlaybackState.paused);
        return true;

      case NativeVideoPlayerAdEventType.adCompleted:
        if (_sessionState != NativeVideoPlayerAdSessionState.adPlaying &&
            _sessionState != NativeVideoPlayerAdSessionState.adPaused) {
          return false;
        }
        _setSessionState(NativeVideoPlayerAdSessionState.adCompleted);
        _setState(NativeVideoPlayerAdPlaybackState.completed);
        return true;

      case NativeVideoPlayerAdEventType.adSkipped:
        if (_sessionState != NativeVideoPlayerAdSessionState.adPlaying &&
            _sessionState != NativeVideoPlayerAdSessionState.adPaused) {
          return false;
        }
        _setSessionState(NativeVideoPlayerAdSessionState.adSkipped);
        _setState(NativeVideoPlayerAdPlaybackState.skipped);
        return true;

      case NativeVideoPlayerAdEventType.breakCompleted:
      case NativeVideoPlayerAdEventType.allAdsCompleted:
        if (_sessionState != NativeVideoPlayerAdSessionState.adPlaying &&
            _sessionState != NativeVideoPlayerAdSessionState.adPaused &&
            _sessionState != NativeVideoPlayerAdSessionState.adCompleted &&
            _sessionState != NativeVideoPlayerAdSessionState.adSkipped) {
          return false;
        }
        _cancelWaterfall();
        _currentBreak = null;
        _setState(NativeVideoPlayerAdPlaybackState.idle);
        _setSessionState(_contentSessionStateFor(_contentActivityState));
        return true;

      case NativeVideoPlayerAdEventType.tagFailed:
        // A per-tag failure is consumed by the waterfall; it must not fail the
        // ad session while tags remain, otherwise a "no fill" on tag 1 would
        // stop the fallback to tag 2.
        return false;

      case NativeVideoPlayerAdEventType.waterfallExhausted:
        // Every tag failed. Now the ad session genuinely fails, and the usual
        // resumeContentOnError policy decides whether content continues.
        return _applyAdSessionFailure();

      case NativeVideoPlayerAdEventType.error:
        // Errors that belong to a single tag are routed to the waterfall,
        // which advances to the next tag or ends the waterfall. Only an error
        // outside a waterfall run fails the ad session directly.
        if (event.error != null && _reportToWaterfall(event.error!)) {
          return false;
        }
        return _applyAdSessionFailure();

      case NativeVideoPlayerAdEventType.adProgress:
      case NativeVideoPlayerAdEventType.firstQuartile:
      case NativeVideoPlayerAdEventType.midpoint:
      case NativeVideoPlayerAdEventType.thirdQuartile:
      case NativeVideoPlayerAdEventType.clicked:
        return _sessionState == NativeVideoPlayerAdSessionState.adPlaying ||
            _sessionState == NativeVideoPlayerAdSessionState.adPaused;

      case NativeVideoPlayerAdEventType.unknown:
        return false;
    }
  }

  /// Fails the whole ad session, honoring [NativeVideoPlayerAdConfiguration
  /// .resumeContentOnError]. Used once a waterfall is exhausted and for
  /// single-tag errors.
  bool _applyAdSessionFailure() {
    final canRecoverFromContent = switch (_sessionState) {
      NativeVideoPlayerAdSessionState.contentInitialized ||
      NativeVideoPlayerAdSessionState.contentLoading ||
      NativeVideoPlayerAdSessionState.contentLoaded => true,
      _ => false,
    };
    if (!canRecoverFromContent &&
        _sessionState != NativeVideoPlayerAdSessionState.adLoading &&
        _sessionState != NativeVideoPlayerAdSessionState.adPlaying &&
        _sessionState != NativeVideoPlayerAdSessionState.adPaused) {
      return false;
    }
    _cancelWaterfall();
    _setSessionState(NativeVideoPlayerAdSessionState.adFailed);
    _setState(NativeVideoPlayerAdPlaybackState.error);
    if (_configuration?.resumeContentOnError ?? true) {
      _currentBreak = null;
      _setState(NativeVideoPlayerAdPlaybackState.idle);
      _setSessionState(_contentSessionStateFor(_contentActivityState));
    }
    return true;
  }

  bool _isAdPhase(NativeVideoPlayerAdSessionState state) => switch (state) {
    NativeVideoPlayerAdSessionState.adLoading ||
    NativeVideoPlayerAdSessionState.adPlaying ||
    NativeVideoPlayerAdSessionState.adPaused ||
    NativeVideoPlayerAdSessionState.adCompleted ||
    NativeVideoPlayerAdSessionState.adSkipped ||
    NativeVideoPlayerAdSessionState.adFailed => true,
    _ => false,
  };

  bool _isContentPhase(NativeVideoPlayerAdSessionState state) =>
      !_isAdPhase(state) && state != NativeVideoPlayerAdSessionState.disposed;

  NativeVideoPlayerAdSessionState _contentSessionStateFor(
    PlayerActivityState state,
  ) => switch (state) {
    PlayerActivityState.idle => NativeVideoPlayerAdSessionState.contentIdle,
    PlayerActivityState.initializing =>
      NativeVideoPlayerAdSessionState.contentInitializing,
    PlayerActivityState.initialized =>
      NativeVideoPlayerAdSessionState.contentInitialized,
    PlayerActivityState.loading =>
      NativeVideoPlayerAdSessionState.contentLoading,
    PlayerActivityState.loaded => NativeVideoPlayerAdSessionState.contentLoaded,
    PlayerActivityState.playing =>
      NativeVideoPlayerAdSessionState.contentPlaying,
    PlayerActivityState.paused => NativeVideoPlayerAdSessionState.contentPaused,
    PlayerActivityState.buffering =>
      NativeVideoPlayerAdSessionState.contentBuffering,
    PlayerActivityState.completed =>
      NativeVideoPlayerAdSessionState.contentCompleted,
    PlayerActivityState.stopped =>
      NativeVideoPlayerAdSessionState.contentStopped,
    PlayerActivityState.error => NativeVideoPlayerAdSessionState.contentError,
  };

  void _setState(NativeVideoPlayerAdPlaybackState state) {
    if (_state == state) {
      return;
    }
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  void _setSessionState(NativeVideoPlayerAdSessionState state) {
    if (_sessionState == state) {
      return;
    }
    _sessionState = state;
    if (!_sessionStateController.isClosed) {
      _sessionStateController.add(state);
    }
  }

  /// Stops any in-flight waterfall without emitting a terminal event.
  void _cancelWaterfall() {
    _waterfall?.cancel();
    _waterfallBreak = null;
  }

  /// Tears down the waterfall and its event bridge.
  Future<void> _disposeWaterfall() async {
    await _waterfallEventSubscription?.cancel();
    _waterfallEventSubscription = null;
    final waterfall = _waterfall;
    _waterfall = null;
    _waterfallBreak = null;
    await waterfall?.dispose();
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _disposeWaterfall();
    _configuration = null;
    _detachPlatform();
    _currentBreak = null;
    _setState(NativeVideoPlayerAdPlaybackState.disposed);
    _setSessionState(NativeVideoPlayerAdSessionState.disposed);
    // StreamController.close waits for a paused listener to resume. A caller's
    // paused ad listener must not prevent the content controller from
    // disposing, so closing is deliberately best-effort here.
    unawaited(_stateController.close());
    unawaited(_sessionStateController.close());
    unawaited(_eventController.close());
    unawaited(_errorController.close());
  }
}

extension _NativeVideoPlayerMidRollScheduling on NativeVideoPlayerController {
  void _resetMidRollSchedule() {
    _triggeredMidRollBreakIds.clear();
    _activeMidRollBreak = null;
    _midRollResumePosition = null;
    _midRollRequestInFlight = false;
  }

  Future<void> _maybeTriggerMidRoll(NativeVideoPlayerState state) async {
    if (_isDisposed ||
        _methodChannel == null ||
        _midRollRequestInFlight ||
        _activeMidRollBreak != null ||
        !advertisementController.isEnabled ||
        state.activityState != PlayerActivityState.playing) {
      return;
    }

    final configuration = advertisementController.configuration;
    if (configuration == null ||
        configuration.tagType == NativeVideoPlayerAdTagType.vmap ||
        configuration.midRollBreaks.isEmpty) {
      return;
    }

    NativeVideoPlayerAdBreak? dueBreak;
    for (final breakInfo in configuration.midRollBreaks) {
      if (!_triggeredMidRollBreakIds.contains(breakInfo.id) &&
          state.currentPosition >= breakInfo.position!) {
        dueBreak = breakInfo;
        break;
      }
    }
    if (dueBreak == null) {
      return;
    }

    _triggeredMidRollBreakIds.add(dueBreak.id);
    _activeMidRollBreak = dueBreak;
    _midRollResumePosition = state.currentPosition;
    _midRollRequestInFlight = true;

    try {
      await advertisementController.requestAdvertisements(
        breakInfo: dueBreak,
      );
    } catch (_) {
      _midRollRequestInFlight = false;
      _activeMidRollBreak = null;
      _midRollResumePosition = null;
    }
  }

  void _handleAdvertisementEvent(Map<dynamic, dynamic> platformEvent) {
    final payload = platformEvent['adEvent'];
    final event = NativeVideoPlayerAdEvent.fromMap(
      payload is Map ? payload : platformEvent,
    );

    if (_activeMidRollBreak == null) {
      return;
    }

    if (event.type == NativeVideoPlayerAdEventType.breakStarted ||
        event.type == NativeVideoPlayerAdEventType.adStarted) {
      _midRollRequestInFlight = false;
      return;
    }

    final shouldRestore =
        event.type == NativeVideoPlayerAdEventType.adSkipped ||
        event.type == NativeVideoPlayerAdEventType.breakCompleted ||
        event.type == NativeVideoPlayerAdEventType.allAdsCompleted ||
        (event.type == NativeVideoPlayerAdEventType.error &&
            (advertisementController.configuration?.resumeContentOnError ??
                true));
    if (!shouldRestore) {
      return;
    }

    final position = _midRollResumePosition;
    _activeMidRollBreak = null;
    _midRollResumePosition = null;
    _midRollRequestInFlight = false;
    if (position == null || _isDisposed || _methodChannel == null) {
      return;
    }

    unawaited(() async {
      await seekTo(position);
      await play();
    }());
  }

  Future<void> _maybeTriggerPostRoll() async {
    if (_isDisposed ||
        _methodChannel == null ||
        _postRollTriggered ||
        _postRollRequestInFlight ||
        !advertisementController.isEnabled) {
      return;
    }

    final configuration = advertisementController.configuration;
    if (configuration == null ||
        configuration.tagType == NativeVideoPlayerAdTagType.vmap ||
        configuration.postRollBreaks.isEmpty) {
      return;
    }

    _postRollTriggered = true;
    _postRollRequestInFlight = true;
    try {
      await advertisementController.requestAdvertisements(
        breakInfo: configuration.postRollBreaks.isEmpty
            ? null
            : configuration.postRollBreaks.first,
        onRequestIssued: () async {
          await _methodChannel!.completeContentForAdvertisement();
        },
      );
    } finally {
      _postRollRequestInFlight = false;
    }
  }
}
