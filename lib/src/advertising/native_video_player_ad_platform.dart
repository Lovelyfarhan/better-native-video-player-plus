import 'native_video_player_ad_configuration.dart';
import 'native_video_player_ad_event.dart';

/// Provider-neutral Flutter-to-native contract for optional ad playback.
///
/// This intentionally describes ad lifecycle actions rather than Google IMA
/// types. The Android and iOS adapters can implement it with their respective
/// IMA SDKs without exposing either SDK to Flutter.
///
/// Commands travel through the package's existing shared player
/// [MethodChannel]. Ad events continue to arrive through the existing
/// controller-level EventChannel in an `advertisement` envelope, which is
/// decoded by [decodeEvent]. No second channel architecture is introduced.
abstract interface class NativeVideoPlayerAdvertisementPlatform {
  /// Creates native advertising resources for one configured content load.
  Future<void> initializeAdvertisement(
    NativeVideoPlayerAdConfiguration configuration,
  );

  /// Requests the configured ad schedule or tag from the native adapter.
  Future<void> requestAdvertisements();

  /// Signals legitimate content completion for a native post-roll schedule.
  Future<void> completeContentForAdvertisement();

  /// Starts the currently prepared advertisement break.
  Future<void> startAdvertisement();

  /// Pauses the current advertisement break.
  Future<void> pauseAdvertisement();

  /// Requests a skip; the native IMA adapter enforces actual eligibility.
  Future<void> skipAdvertisement();

  /// Resumes the current advertisement break.
  Future<void> resumeAdvertisement();

  /// Stops the current advertisement break without destroying the adapter.
  Future<void> stopAdvertisement();

  /// Releases native advertising resources for this player.
  Future<void> destroyAdvertisement();

  /// Converts an event received on the existing controller EventChannel into
  /// the package's provider-neutral ad event model.
  NativeVideoPlayerAdEvent decodeEvent(Map<dynamic, dynamic> platformEvent);
}
