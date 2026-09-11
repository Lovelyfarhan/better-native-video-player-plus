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

  /// Requests the active native ad to skip when IMA permits it.
  Future<void> skipAdvertisement() async {
    await _platform?.skipAdvertisement();
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
        _currentBreak = null;
        _setState(NativeVideoPlayerAdPlaybackState.idle);
        _setSessionState(_contentSessionStateFor(_contentActivityState));
        return true;

      case NativeVideoPlayerAdEventType.error:
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
        _setSessionState(NativeVideoPlayerAdSessionState.adFailed);
        _setState(NativeVideoPlayerAdPlaybackState.error);
        if (_configuration!.resumeContentOnError) {
          _currentBreak = null;
          _setState(NativeVideoPlayerAdPlaybackState.idle);
          _setSessionState(_contentSessionStateFor(_contentActivityState));
        }
        return true;

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

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
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
      await _methodChannel!.initializeAdvertisement(configuration);
      await _methodChannel!.requestAdvertisements();
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
      await _methodChannel!.initializeAdvertisement(configuration);
      await _methodChannel!.requestAdvertisements();
      await _methodChannel!.completeContentForAdvertisement();
    } finally {
      _postRollRequestInFlight = false;
    }
  }
}
