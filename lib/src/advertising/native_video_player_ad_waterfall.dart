import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_video_player_ad_configuration.dart';
import 'native_video_player_ad_event.dart';

/// State of one tag inside a multi-tag VAST waterfall.
enum NativeVideoPlayerAdWaterfallTagState {
  /// The tag has not been requested yet.
  pending,

  /// The tag is currently being requested and awaited.
  requesting,

  /// The tag loaded a playable ad and is now the active tag.
  filled,

  /// The tag reported no ad or timed out.
  noFill,

  /// The tag reported a non-recoverable error.
  failed,
}

/// Immutable snapshot of one waterfall tag.
@immutable
class NativeVideoPlayerAdWaterfallTag {
  /// Creates a tag entry for the waterfall snapshot.
  const NativeVideoPlayerAdWaterfallTag({
    required this.url,
    required this.index,
    this.state = NativeVideoPlayerAdWaterfallTagState.pending,
    this.error,
  });

  /// The VAST tag URL.
  final Uri url;

  /// Zero-based position in the waterfall.
  final int index;

  /// Current request state of this tag.
  final NativeVideoPlayerAdWaterfallTagState state;

  /// Error that ended this tag's attempt, when one was reported.
  final NativeVideoPlayerAdError? error;

  /// Whether this tag is the one currently being requested.
  bool get isRequesting =>
      state == NativeVideoPlayerAdWaterfallTagState.requesting;
}

/// Reason the waterfall ended without playing an ad.
enum NativeVideoPlayerAdWaterfallStopReason {
  /// Every tag reported no ad (no fill / empty response / timeout).
  allTagsExhausted,

  /// A tag reported a non-recoverable error that stopped the waterfall.
  fatalError,

  /// The ad session was cancelled or disposed before a tag filled.
  cancelled,
}

/// Callbacks fired by [NativeVideoPlayerAdWaterfallManager].
///
/// Every callback is optional; the manager works without any observer. The
/// manager also emits the same information as [NativeVideoPlayerAdEvent]s
/// through its [NativeVideoPlayerAdWaterfallManager.events] stream, which is
/// the surface the controller forwards to applications.
@immutable
class NativeVideoPlayerAdWaterfallCallbacks {
  /// Creates a set of waterfall callbacks.
  const NativeVideoPlayerAdWaterfallCallbacks({
    this.onTagRequested,
    this.onTagFailed,
    this.onAdStarted,
    this.onAllTagsFailed,
    this.onTagFilled,
  });

  /// Called immediately before a tag is requested. [index] is zero-based.
  final void Function(Uri tag, int index, int total)? onTagRequested;

  /// Called when a tag is abandoned (no fill, timeout, or error) and the
  /// waterfall advances. [nextIndex] is null when no tag remains.
  final void Function(
    Uri tag,
    int index,
    NativeVideoPlayerAdError error,
    int? nextIndex,
  )?
  onTagFailed;

  /// Called once the first ad of the resolved tag actually starts playing.
  final void Function(Uri tag, int index)? onAdStarted;

  /// Called when every tag has been exhausted without a playable ad.
  final void Function(NativeVideoPlayerAdWaterfallStopReason reason)?
  onAllTagsFailed;

  /// Called when a tag reports a loadable ad (before playback starts).
  final void Function(Uri tag, int index)? onTagFilled;
}

/// Drives an ordered VAST tag waterfall for one ad break.
///
/// The manager is deliberately transport-agnostic: it does not talk to Google
/// IMA directly. Instead it asks the owner (the advertisement controller) to
/// request a tag and reports back what should happen next. That keeps the
/// fallback policy — which is pure logic and easy to test — separate from the
/// native bridge, and lets a single `AdsLoader` be reused across tags: the
/// owner destroys only the previous `AdsManager`, never the loader.
///
/// ## Lifecycle
///
/// 1. [start] records the tag list and asks for the first tag.
/// 2. Each tag attempt is bounded by [NativeVideoPlayerAdConfiguration
///    .perTagTimeout]; on expiry the tag is treated as no fill.
/// 3. On [onTagNoFill]/[onTagFailed] the manager destroys the failed attempt
///    and advances to the next tag.
/// 4. On [onTagLoaded] the current tag is marked filled and playback begins.
/// 5. On [onAdStarted] the waterfall is considered resolved.
/// 6. [cancel] (or [dispose]) stops the waterfall; a late native event for a
///    cancelled request is ignored.
///
/// ## Which failures continue the waterfall
///
/// "No fill" errors — [isNoFillError] — always advance to the next tag:
///
/// * `VAST_EMPTY_RESPONSE` — the VAST document contains no `<Ad>`.
/// * `VAST_NO_ADS_AFTER_WRAPPER` — wrapper resolved to nothing.
/// * `VAST_MEDIA_LOAD_TIMEOUT` — the selected media never became playable.
/// * `AD_BREAK_FETCH_ERROR` / `IMA_AD_LOAD_ERROR` / `LOAD_ERROR` — the ad
///   server could not be reached.
/// * `IMA_AD_ERROR` / `IMA_OPERATION_FAILED` / `AD_PLAYER_ERROR` whose message
///   mentions no fill/empty/no ads.
///
/// Any other error (schema errors, invalid tags, adapter failures) is treated
/// as fatal by default and stops the waterfall, because retrying a malformed
/// request against more tags only wastes the user's time. Pass
/// [continueOnFatalErrors] to keep advancing even then.
class NativeVideoPlayerAdWaterfallManager {
  /// Creates a waterfall manager.
  ///
  /// [requestTag] is invoked to ask the native adapter to request a tag; it
  /// must not throw. [onTagAbandoned] is invoked when the manager wants the
  /// previous attempt torn down before the next tag is requested (destroy the
  /// `AdsManager`, keep the `AdsLoader`).
  NativeVideoPlayerAdWaterfallManager({
    required Future<void> Function(
      NativeVideoPlayerAdConfiguration configuration,
    )
    requestTag,
    Future<void> Function()? onTagAbandoned,
    NativeVideoPlayerAdWaterfallCallbacks callbacks =
        const NativeVideoPlayerAdWaterfallCallbacks(),
    bool continueOnFatalErrors = false,
  }) : _requestTag = requestTag,
       _onTagAbandoned = onTagAbandoned,
       _callbacks = callbacks,
       _continueOnFatalErrors = continueOnFatalErrors;

  final Future<void> Function(NativeVideoPlayerAdConfiguration configuration)
  _requestTag;
  final Future<void> Function()? _onTagAbandoned;
  final bool _continueOnFatalErrors;
  NativeVideoPlayerAdWaterfallCallbacks _callbacks;

  final StreamController<NativeVideoPlayerAdEvent> _eventController =
      StreamController<NativeVideoPlayerAdEvent>.broadcast();

  /// Ordered tag list for the active waterfall. Empty when idle.
  List<Uri> _tags = const <Uri>[];
  int _index = -1;
  bool _running = false;
  bool _disposed = false;
  Timer? _tagTimer;

  /// The configuration used to request each tag. Its `adTagUrl` is rewritten
  /// to the tag currently being requested.
  NativeVideoPlayerAdConfiguration? _configuration;

  /// Emits the same waterfall milestones as the callbacks, as normalized ad
  /// events. The controller merges this into the public ad event stream.
  Stream<NativeVideoPlayerAdEvent> get events => _eventController.stream;

  /// Whether a waterfall is currently in progress.
  bool get isRunning => _running;

  /// Zero-based index of the tag currently being requested, or -1 when idle.
  int get currentIndex => _index;

  /// Total number of tags in the active waterfall.
  int get totalTags => _tags.length;

  /// The tag currently being requested, or null when idle.
  Uri? get currentTag =>
      _index >= 0 && _index < _tags.length ? _tags[_index] : null;

  /// Immutable snapshot of every tag and its state.
  List<NativeVideoPlayerAdWaterfallTag> get snapshot =>
      List<NativeVideoPlayerAdWaterfallTag>.generate(
        _tags.length,
        (i) => NativeVideoPlayerAdWaterfallTag(
          url: _tags[i],
          index: i,
          state: _states[i],
          error: _errors[i],
        ),
        growable: false,
      );

  final List<NativeVideoPlayerAdWaterfallTagState> _states =
      <NativeVideoPlayerAdWaterfallTagState>[];
  final List<NativeVideoPlayerAdError?> _errors = <NativeVideoPlayerAdError?>[];

  /// Replaces the callback set (for example when a controller is reused).
  set callbacks(NativeVideoPlayerAdWaterfallCallbacks value) =>
      _callbacks = value;

  /// Starts the waterfall for [configuration].
  ///
  /// Returns true when a request was issued, false when the configuration has
  /// no tag to request or the manager is disposed. Any previous run is
  /// cancelled first, so calling this twice cannot leave two timers alive.
  bool start(NativeVideoPlayerAdConfiguration configuration) {
    if (_disposed) {
      return false;
    }
    cancel(reason: NativeVideoPlayerAdWaterfallStopReason.cancelled);

    final tags = configuration.waterfallTags;
    if (tags.isEmpty) {
      return false;
    }

    _configuration = configuration;
    _tags = tags;
    _states
      ..clear()
      ..addAll(
        List<NativeVideoPlayerAdWaterfallTagState>.filled(
          tags.length,
          NativeVideoPlayerAdWaterfallTagState.pending,
        ),
      );
    _errors
      ..clear()
      ..addAll(List<NativeVideoPlayerAdError?>.filled(tags.length, null));
    _index = 0;
    _running = true;

    _requestCurrent();
    return true;
  }

  /// Marks the tag currently being requested as loadable.
  ///
  /// Called when the native adapter reports `breakReady`/`LOADED`. Playback
  /// has not necessarily started yet; the waterfall stays armed so a media
  /// failure during playback can still fall through (see [onPlaybackError]).
  void onTagLoaded() {
    if (!_running || _index < 0) {
      return;
    }
    _cancelTagTimer();
    _states[_index] = NativeVideoPlayerAdWaterfallTagState.filled;
    _callbacks.onTagFilled?.call(_tags[_index], _index);
  }

  /// Marks the current tag as filled and resolves the waterfall.
  ///
  /// Called when an ad actually starts playing. After this the waterfall is
  /// idle and a later failure is a normal ad-session failure, not a fallback
  /// trigger.
  void onAdStarted() {
    if (!_running || _index < 0) {
      return;
    }
    _cancelTagTimer();
    final tag = _tags[_index];
    final index = _index;
    _states[index] = NativeVideoPlayerAdWaterfallTagState.filled;
    _finish();
    _callbacks.onAdStarted?.call(tag, index);
  }

  /// Reports that the current tag produced no ad and should be abandoned.
  ///
  /// [error] is surfaced through the event stream so the application can log
  /// which tag failed and why. Returns true when another tag was requested.
  bool onTagNoFill(NativeVideoPlayerAdError error) =>
      _abandonCurrentTag(error, advance: true);

  /// Reports a non-recoverable error for the current tag.
  ///
  /// Advances to the next tag only when the error looks like no fill or
  /// [continueOnFatalErrors] is enabled; otherwise the waterfall ends with
  /// [NativeVideoPlayerAdWaterfallStopReason.fatalError].
  bool onTagFailed(NativeVideoPlayerAdError error) {
    final advance = _continueOnFatalErrors || isNoFillError(error);
    return _abandonCurrentTag(error, advance: advance);
  }

  /// Reports a playback-time failure for the current tag.
  ///
  /// A media error after `breakReady` (for example the creative URL 404s) is
  /// not a "no fill" error, but it still means this tag cannot deliver a
  /// playable ad, so the waterfall advances when tags remain.
  bool onPlaybackError(NativeVideoPlayerAdError error) {
    if (!_running) {
      return false;
    }
    return _abandonCurrentTag(error, advance: true);
  }

  /// Cancels an in-flight waterfall without emitting a terminal event.
  ///
  /// Used when content is disposed, reloaded, or when the waterfall has
  /// already resolved successfully.
  void cancel({NativeVideoPlayerAdWaterfallStopReason? reason}) {
    _cancelTagTimer();
    final wasRunning = _running;
    _running = false;
    _index = -1;
    _tags = const <Uri>[];
    _states.clear();
    _errors.clear();
    _configuration = null;
    if (wasRunning && reason != null) {
      _callbacks.onAllTagsFailed?.call(reason);
    }
  }

  /// Releases the manager. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    cancel();
    await _eventController.close();
  }

  bool _abandonCurrentTag(
    NativeVideoPlayerAdError error, {
    required bool advance,
  }) {
    if (!_running || _index < 0 || _index >= _tags.length) {
      return false;
    }
    _cancelTagTimer();
    final tag = _tags[_index];
    final index = _index;
    _states[index] = advance
        ? NativeVideoPlayerAdWaterfallTagState.noFill
        : NativeVideoPlayerAdWaterfallTagState.failed;
    _errors[index] = error;

    final hasNext = advance && index + 1 < _tags.length;
    final nextIndex = hasNext ? index + 1 : null;
    _callbacks.onTagFailed?.call(tag, index, error, nextIndex);
    _emitWaterfallEvent(
      NativeVideoPlayerAdEventType.tagFailed,
      tag: tag,
      index: index,
      error: error,
      extra: <String, Object?>{'willFallback': hasNext},
    );

    if (!hasNext) {
      final reason = advance
          ? NativeVideoPlayerAdWaterfallStopReason.allTagsExhausted
          : NativeVideoPlayerAdWaterfallStopReason.fatalError;
      _finish();
      _callbacks.onAllTagsFailed?.call(reason);
      _emitWaterfallEvent(
        NativeVideoPlayerAdEventType.waterfallExhausted,
        tag: tag,
        index: index,
        error: error,
        extra: <String, Object?>{'reason': reason.name},
      );
      return false;
    }

    // Destroy the previous AdsManager before requesting the next tag. The
    // AdsLoader itself is owned by the caller and is intentionally reused.
    final abandoned = _onTagAbandoned;
    if (abandoned != null) {
      unawaited(
        abandoned().catchError(
          (Object error, StackTrace stackTrace) => debugPrint(
            'Ad waterfall: abandoning the previous tag failed: $error',
          ),
        ),
      );
    }

    _index = index + 1;
    _requestCurrent();
    return true;
  }

  void _requestCurrent() {
    if (!_running || _index < 0 || _index >= _tags.length) {
      return;
    }
    final configuration = _configuration;
    if (configuration == null) {
      cancel();
      return;
    }
    final tag = _tags[_index];
    final index = _index;
    _states[index] = NativeVideoPlayerAdWaterfallTagState.requesting;
    _errors[index] = null;

    _callbacks.onTagRequested?.call(tag, index, _tags.length);
    _emitWaterfallEvent(
      NativeVideoPlayerAdEventType.tagRequested,
      tag: tag,
      index: index,
    );

    // Each tag is requested with the break's schedule intact and only the tag
    // URL swapped, so skip policy, metadata, and resume policy stay identical
    // across fallbacks. `vastTags` is cleared so a nested waterfall can never
    // be started from within a running one.
    final tagConfiguration = NativeVideoPlayerAdConfiguration(
      adTagUrl: tag,
      tagType: configuration.tagType,
      enabled: configuration.enabled,
      adBreaks: configuration.adBreaks,
      timeout: configuration.timeout,
      skipConfiguration: configuration.skipConfiguration,
      requestMetadata: configuration.requestMetadata,
      resumeContentOnError: configuration.resumeContentOnError,
      perTagTimeout: configuration.perTagTimeout,
    );
    unawaited(
      _requestTag(tagConfiguration).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        debugPrint('Ad waterfall: requesting tag $index failed: $error');
        onTagFailed(
          NativeVideoPlayerAdError(
            code: 'AD_TAG_REQUEST_FAILED',
            message: 'Failed to request ad tag: $error',
          ),
        );
      }),
    );

    _armTagTimer(index);
  }

  void _armTagTimer(int index) {
    _cancelTagTimer();
    final timeout = _configuration?.perTagTimeout;
    if (timeout == null || timeout <= Duration.zero) {
      return;
    }
    _tagTimer = Timer(timeout, () {
      if (!_running || _index != index) {
        return;
      }
      // A tag that neither loaded nor errored in time is treated as no fill so
      // the user never waits on a single slow or empty ad server.
      onTagNoFill(
        NativeVideoPlayerAdError(
          code: 'AD_TAG_TIMEOUT',
          message:
              'Ad tag did not respond within '
              '${timeout.inMilliseconds} ms.',
          details: <String, Object?>{
            'tagIndex': index,
            'tagUrl': _tags[index].toString(),
            'timeoutMs': timeout.inMilliseconds,
          },
        ),
      );
    });
  }

  void _cancelTagTimer() {
    _tagTimer?.cancel();
    _tagTimer = null;
  }

  void _finish() {
    _cancelTagTimer();
    _running = false;
    _index = -1;
  }

  void _emitWaterfallEvent(
    NativeVideoPlayerAdEventType type, {
    required Uri tag,
    required int index,
    NativeVideoPlayerAdError? error,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    if (_eventController.isClosed) {
      return;
    }
    _eventController.add(
      NativeVideoPlayerAdEvent(
        type: type,
        rawType: type.name,
        error: error,
        adTagUrl: tag,
        tagIndex: index,
        totalTags: _tags.length,
        metadata: extra.isEmpty
            ? null
            : NativeVideoPlayerAdMetadata(adSystem: extra.toString()),
      ),
    );
  }

  /// Whether [error] should be treated as "no fill" so the waterfall keeps
  /// trying the remaining tags.
  ///
  /// Covers the IMA codes that mean "this tag produced nothing": an empty VAST
  /// document, a wrapper that resolved to no ads, a fetch/load failure, and a
  /// media load timeout. Errors whose message mentions no fill/empty/no ads are
  /// also treated as no fill even when the provider uses a different code.
  static bool isNoFillError(NativeVideoPlayerAdError error) {
    const noFillCodes = <String>{
      'VAST_EMPTY_RESPONSE',
      'VAST_NO_ADS_AFTER_WRAPPER',
      'VAST_MEDIA_LOAD_TIMEOUT',
      'AD_BREAK_FETCH_ERROR',
      'LOAD_ERROR',
      'IMA_AD_LOAD_ERROR',
      'IMA_AD_ERROR',
      'IMA_OPERATION_FAILED',
      'AD_PLAYER_ERROR',
      'AD_TAG_TIMEOUT',
      'AD_TAG_REQUEST_FAILED',
    };
    if (noFillCodes.contains(error.code)) {
      return true;
    }
    final message = error.message.toLowerCase();
    return message.contains('no ad') ||
        message.contains('no fill') ||
        message.contains('empty vast') ||
        message.contains('no ads') ||
        message.contains('does not contain any ads') ||
        message.contains('vast response is empty') ||
        message.contains('no valid ad');
  }
}
