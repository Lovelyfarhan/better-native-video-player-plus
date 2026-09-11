package com.huddlecommunity.better_native_video_player.ads

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.google.ads.interactivemedia.v3.api.AdErrorEvent
import com.google.ads.interactivemedia.v3.api.AdEvent
import com.google.ads.interactivemedia.v3.api.AdsLoader
import com.google.ads.interactivemedia.v3.api.AdsManager
import com.google.ads.interactivemedia.v3.api.AdsManagerLoadedEvent
import com.google.ads.interactivemedia.v3.api.AdsRenderingSettings
import com.google.ads.interactivemedia.v3.api.AdPodInfo
import com.google.ads.interactivemedia.v3.api.ImaSdkFactory
import com.google.ads.interactivemedia.v3.api.ImaSdkSettings
import com.google.ads.interactivemedia.v3.api.player.AdMediaInfo
import com.google.ads.interactivemedia.v3.api.player.ContentProgressProvider
import com.google.ads.interactivemedia.v3.api.player.VideoAdPlayer
import com.google.ads.interactivemedia.v3.api.player.VideoProgressUpdate
import com.huddlecommunity.better_native_video_player.NativeVideoPlayerPlugin
import com.huddlecommunity.better_native_video_player.NpLog
import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * Android implementation of the provider-neutral advertising method-channel
 * contract. The content [ExoPlayer] remains independent and is paused/resumed
 * only in response to IMA's content lifecycle callbacks.
 *
 * This class is intentionally created by [VideoPlayerView] rather than the
 * shared content-player manager: IMA requires a native view to own its ad UI.
 * No IMA resource is allocated until `advertisementInitialize` is invoked.
 */
@UnstableApi
internal class ImaAdvertisementBridge(
    private val applicationContext: Context,
    private val controllerId: Int?,
    private val contentPlayer: ExoPlayer,
    private var overlayHost: ViewGroup,
) : AdsLoader.AdsLoadedListener, AdErrorEvent.AdErrorListener, AdEvent.AdEventListener {

    companion object {
        private const val TAG = "ImaAdvertisementBridge"
        private const val EVENT_NAME = "advertisement"
        private const val VIDEO_TIME_NOT_READY = -1L
    }

    private val imaSdkFactory = ImaSdkFactory.getInstance()

    private var configuration: AdvertisementConfiguration? = null
    private var adsLoader: AdsLoader? = null
    private var adsManager: AdsManager? = null
    private var adContainer: FrameLayout? = null
    private var adPlayerAdapter: ImaExoVideoAdPlayer? = null
    private var contentWasPlayingBeforeAd = false
    private var shouldResumeContentAfterAd = false
    private var adStartRequested = false
    private var isVmap = false
    private var resumeContentOnError = true
    private var requestInFlight = false
    private var contentListenerAttached = false
    private var destroyed = false

    private val contentCompletionListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) {
                adsLoader?.contentComplete()
            }
        }
    }

    /** Handles only the reserved advertisement method-channel calls. */
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (!call.method.startsWith("advertisement")) {
            return false
        }

        try {
            when (call.method) {
                "advertisementInitialize" -> {
                    initialize(parseConfiguration(call))
                    result.success(null)
                }

                "advertisementRequestAds" -> {
                    requestAds()
                    result.success(null)
                }
                "advertisementContentComplete" -> {
                    adsLoader?.contentComplete()
                    result.success(null)
                }

                "advertisementStart" -> {
                    requireManager("start").start()
                    result.success(null)
                }

                "advertisementPause" -> {
                    requireManager("pause").pause()
                    result.success(null)
                }
                "advertisementSkip" -> {
                    requireManager("skip").skip()
                    result.success(null)
                }

                "advertisementResume" -> {
                    requireManager("resume").resume()
                    result.success(null)
                }

                "advertisementStop" -> {
                    stopCurrentAdvertisement()
                    result.success(null)
                }

                "advertisementDestroy" -> {
                    destroy()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (error: AdvertisementBridgeException) {
            handleAdvertisementFailure(error.code, error.message)
            result.error(error.code, error.message, null)
        } catch (error: Exception) {
            NpLog.e(TAG, "IMA ${call.method} failed: ${error.message}")
            handleAdvertisementFailure("IMA_OPERATION_FAILED", error.message ?: "Google IMA operation failed.")
            result.error("IMA_OPERATION_FAILED", error.message, null)
        }
        return true
    }

    /** Moves IMA's UI with the content view during native fullscreen changes. */
    fun moveOverlayTo(newHost: ViewGroup) {
        overlayHost = newHost
        val container = adContainer ?: return
        (container.parent as? ViewGroup)?.removeView(container)
        newHost.addView(
            container,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    override fun onAdsManagerLoaded(event: AdsManagerLoadedEvent) {
        val loadedManager = event.adsManager
        if (loadedManager == null) {
            handleAdvertisementFailure("IMA_MANAGER_UNAVAILABLE", "Google IMA did not provide an ads manager.")
            return
        }
        releaseAdsManager()
        adsManager = loadedManager
        loadedManager.addAdErrorListener(this)
        loadedManager.addAdEventListener(this)

        val renderingSettings = imaSdkFactory.createAdsRenderingSettings()
        configuration?.timeoutMs?.let { timeoutMs ->
            renderingSettings.setLoadVideoTimeout(
                timeoutMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            )
        }
        loadedManager.init(renderingSettings)
    }

    override fun onAdError(event: AdErrorEvent) {
        val error = event.error
        handleAdvertisementFailure(error.errorCode.name, error.message)
    }

    override fun onAdEvent(event: AdEvent) {
        // Compare enum names rather than taking a dependency on every IMA enum
        // member. IMA has added event types across SDK releases and unknown ones
        // should not alter the Flutter state machine.
        when (event.type.name) {
            "LOADED" -> {
                emitEvent("breakReady", event)
                if (!isVmap && !adStartRequested) {
                    adStartRequested = true
                    adsManager?.start()
                }
            }
            "AD_BREAK_READY" -> emitEvent("breakReady", event)
            "AD_BREAK_STARTED" -> emitEvent("breakStarted", event)
            "STARTED" -> emitEvent("adStarted", event)
            "FIRST_QUARTILE" -> emitEvent("firstQuartile", event)
            "MIDPOINT" -> emitEvent("midpoint", event)
            "THIRD_QUARTILE" -> emitEvent("thirdQuartile", event)
            "PAUSED" -> emitEvent("adPaused", event)
            "RESUMED" -> emitEvent("adResumed", event)
            "SKIPPED" -> emitEvent("adSkipped", event)
            "COMPLETED" -> emitEvent("adCompleted", event)
            "AD_BREAK_ENDED" -> emitEvent("breakCompleted", event)
            "ALL_ADS_COMPLETED" -> {
                requestInFlight = false
                emitEvent("allAdsCompleted", event)
                hideAdContainer()
                resumeContentAfterAdvertisement()
                releaseAdsManager()
            }

            "CLICKED", "TAPPED" -> emitEvent("clicked", event)
            "AD_PROGRESS" -> emitEvent("adProgress", event)
            "AD_BREAK_FETCH_ERROR" -> {
                handleAdvertisementFailure("AD_BREAK_FETCH_ERROR", "Google IMA could not fetch an advertisement break.")
            }

            "CONTENT_PAUSE_REQUESTED" -> {
                pauseContentForAdvertisement()
                showAdContainer()
            }

            "CONTENT_RESUME_REQUESTED" -> {
                hideAdContainer()
                resumeContentAfterAdvertisement()
            }
        }
    }

    /** Releases all IMA and ad-player resources. It is safe to call repeatedly. */
    fun destroy() {
        if (destroyed) return
        destroyed = true

        contentWasPlayingBeforeAd = false
        shouldResumeContentAfterAd = false
        adStartRequested = false
        isVmap = false
        requestInFlight = false
        hideAdContainer()
        releaseAdsManager()

        adsLoader?.removeAdsLoadedListener(this)
        adsLoader?.removeAdErrorListener(this)
        adsLoader?.release()
        adsLoader = null

        if (contentListenerAttached) {
            contentPlayer.removeListener(contentCompletionListener)
            contentListenerAttached = false
        }

        adPlayerAdapter?.dispose()
        adPlayerAdapter = null

        adContainer?.let { container ->
            (container.parent as? ViewGroup)?.removeView(container)
        }
        adContainer = null
        configuration = null
    }

    private fun initialize(newConfiguration: AdvertisementConfiguration) {
        destroy()
        destroyed = false
        configuration = newConfiguration

        // A disabled configuration is a supported no-op. Existing playback is
        // unaffected and no IMA object, view, or listener is retained.
        if (!newConfiguration.enabled) return

        val adPlayer = ExoPlayer.Builder(applicationContext)
            .setAudioAttributes(AudioAttributes.DEFAULT, true)
            .build()
        val adapter = ImaExoVideoAdPlayer(adPlayer) { message ->
            handleAdvertisementFailure("AD_PLAYER_ERROR", message)
        }
        val container = FrameLayout(applicationContext).apply {
            visibility = View.GONE
            addView(
                PlayerView(applicationContext).apply {
                    player = adPlayer
                    useController = false
                },
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        overlayHost.addView(
            container,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        adContainer = container
        adPlayerAdapter = adapter

        val settings = imaSdkFactory.createImaSdkSettings().apply {
            setPlayerType("better_native_video_player")
            // IMA owns VAST/VMAP scheduling, while this bridge starts the
            // loaded pre-roll exactly once from the LOADED event.
            setAutoPlayAdBreaks(isVmap)
        }
        val imaContext = NativeVideoPlayerPlugin.getActivity() ?: applicationContext
        imaSdkFactory.initialize(imaContext, settings)
        val displayContainer = ImaSdkFactory.createAdDisplayContainer(container, adapter)
        adsLoader = imaSdkFactory.createAdsLoader(imaContext, settings, displayContainer).also { loader ->
            loader.addAdsLoadedListener(this)
            loader.addAdErrorListener(this)
        }

        contentPlayer.addListener(contentCompletionListener)
        contentListenerAttached = true
    }

    private fun requestAds() {
        if (requestInFlight) return
        val activeConfiguration = configuration
            ?: throw AdvertisementBridgeException("AD_NOT_INITIALIZED", "Initialize advertisements before requesting them.")
        if (!activeConfiguration.enabled) return
        val loader = adsLoader
            ?: throw AdvertisementBridgeException("AD_NOT_INITIALIZED", "Google IMA is not initialized.")

        pauseContentForAdvertisement()
        adStartRequested = false
        val request = imaSdkFactory.createAdsRequest().apply {
            setAdTagUrl(activeConfiguration.adTagUrl)
            setContentProgressProvider(ContentProgressProvider {
                contentProgress()
            })
            setAdWillAutoPlay(true)
            setAdWillPlayMuted(contentPlayer.volume <= 0f)
            activeConfiguration.contentTitle?.let { setContentTitle(it) }
            activeConfiguration.timeoutMs?.let { timeoutMs ->
                setVastLoadTimeout(timeoutMs.toFloat() / 1000f)
            }
        }
        shouldResumeContentAfterAd = !activeConfiguration.isPostRoll
        resumeContentOnError = activeConfiguration.resumeContentOnError
        requestInFlight = true
        emitEvent("requestStarted")
        loader.requestAds(request)
    }

    private fun contentProgress(): VideoProgressUpdate {
        val duration = contentPlayer.duration
        return if (
            duration == C.TIME_UNSET ||
            duration <= 0L ||
            contentPlayer.currentMediaItem == null
        ) {
            VideoProgressUpdate.VIDEO_TIME_NOT_READY
        } else {
            VideoProgressUpdate(contentPlayer.currentPosition, duration)
        }
    }

    private fun requireManager(operation: String): AdsManager = adsManager
        ?: throw AdvertisementBridgeException(
            "AD_NOT_READY",
            "Cannot $operation an advertisement before Google IMA has loaded it.",
        )

    private fun stopCurrentAdvertisement() {
        // The Android IMA AdsManager does not expose a stop() method. Destroying
        // the current manager is its documented lifecycle operation for ending
        // an ad break; the AdsLoader remains reusable for a later request.
        releaseAdsManager()
        hideAdContainer()
        resumeContentAfterAdvertisement()
    }

    private fun releaseAdsManager() {
        val manager = adsManager ?: return
        adsManager = null
        manager.removeAdErrorListener(this)
        manager.removeAdEventListener(this)
        manager.destroy()
    }

    private fun pauseContentForAdvertisement() {
        if (contentWasPlayingBeforeAd) return
        contentWasPlayingBeforeAd = contentPlayer.playWhenReady
        contentPlayer.pause()
    }

    private fun resumeContentAfterAdvertisement() {
        if (contentWasPlayingBeforeAd || shouldResumeContentAfterAd) {
            contentPlayer.play()
        }
        contentWasPlayingBeforeAd = false
        shouldResumeContentAfterAd = false
    }

    private fun showAdContainer() {
        adContainer?.visibility = View.VISIBLE
    }

    private fun hideAdContainer() {
        adContainer?.visibility = View.GONE
    }

    private fun emitEvent(type: String, adEvent: AdEvent? = null) {
        val fields = mutableMapOf<String, Any?>("adEventType" to type)
        adEvent?.ad?.let { ad ->
            fields["metadata"] = buildMap<String, Any?> {
                ad.adId?.let { put("adId", it) }
                ad.creativeId?.let { put("creativeId", it) }
                ad.adSystem?.let { put("adSystem", it) }
                ad.title?.let { put("title", it) }
                ad.advertiserName?.let { put("advertiserName", it) }
                if (ad.duration >= 0.0) {
                    put("durationMs", (ad.duration * 1000.0).toLong())
                }
                put("isSkippable", ad.isSkippable)
                if (ad.skipTimeOffset >= 0.0) {
                    put("skipTimeOffsetMs", (ad.skipTimeOffset * 1000.0).toLong())
                }
            }
            ad.adPodInfo?.let { podInfo ->
                fields["adPositionInPod"] = podInfo.adPosition
                fields["totalAdsInPod"] = podInfo.totalAds
            }
        }
        if (type == "adProgress") {
            adPlayerAdapter?.adProgressUpdate?.let { progress ->
                if (progress.currentTimeMs != VIDEO_TIME_NOT_READY) {
                    fields["positionMs"] = progress.currentTimeMs
                    fields["durationMs"] = progress.durationMs
                }
            }
        }
        sendToFlutter(fields)
    }

    private fun emitError(code: String, message: String) {
        sendToFlutter(
            mapOf(
                "adEventType" to "error",
                "error" to mapOf(
                    "code" to code,
                    "message" to message,
                ),
            ),
        )
    }

    private fun handleAdvertisementFailure(code: String, message: String) {
        requestInFlight = false
        emitError(code, message)
        hideAdContainer()
        releaseAdsManager()
        if (configuration?.resumeContentOnError ?: resumeContentOnError) {
            resumeContentAfterAdvertisement()
        } else {
            contentWasPlayingBeforeAd = false
            shouldResumeContentAfterAd = false
        }
    }

    private fun sendToFlutter(adEvent: Map<String, Any?>) {
        val id = controllerId ?: return
        SharedPlayerManager.sendControllerEvent(
            id,
            EVENT_NAME,
            mapOf("adEvent" to adEvent),
        )
    }

    private fun parseConfiguration(call: MethodCall): AdvertisementConfiguration {
        val arguments = call.arguments as? Map<*, *>
            ?: throw AdvertisementBridgeException("INVALID_AD_CONFIGURATION", "Missing advertisement configuration.")
        val rawConfiguration = arguments["adConfiguration"] as? Map<*, *>
            ?: throw AdvertisementBridgeException("INVALID_AD_CONFIGURATION", "Missing advertisement configuration.")
        val tagUrl = rawConfiguration["adTagUrl"] as? String
            ?: throw AdvertisementBridgeException("INVALID_AD_CONFIGURATION", "An advertisement tag URL is required.")
        if (tagUrl.isBlank()) {
            throw AdvertisementBridgeException("INVALID_AD_CONFIGURATION", "An advertisement tag URL is required.")
        }
        val metadata = rawConfiguration["requestMetadata"] as? Map<*, *>
        isVmap = rawConfiguration["tagType"] == "vmap"
        return AdvertisementConfiguration(
            enabled = rawConfiguration["enabled"] as? Boolean ?: true,
            adTagUrl = tagUrl,
            timeoutMs = (rawConfiguration["timeoutMs"] as? Number)?.toLong()?.takeIf { it >= 0L },
            contentTitle = metadata?.get("contentTitle") as? String,
            isPostRoll = (rawConfiguration["adBreaks"] as? List<*>)
                ?.any { (it as? Map<*, *>)?.get("type") == "postRoll" } == true,
            resumeContentOnError = rawConfiguration["resumeContentOnError"] as? Boolean ?: true,
        )
    }

    private data class AdvertisementConfiguration(
        val enabled: Boolean,
        val adTagUrl: String,
        val timeoutMs: Long?,
        val contentTitle: String?,
        val isPostRoll: Boolean,
        val resumeContentOnError: Boolean,
    )

    private class AdvertisementBridgeException(
        val code: String,
        override val message: String,
    ) : IllegalStateException(message)
}

/** IMA's [VideoAdPlayer] adapter backed by a dedicated Media3 ExoPlayer. */
@UnstableApi
private class ImaExoVideoAdPlayer(
    private val player: ExoPlayer,
    private val onPlaybackFailure: (String) -> Unit,
) : VideoAdPlayer {

    private val callbacks = linkedSetOf<VideoAdPlayer.VideoAdPlayerCallback>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var currentAd: AdMediaInfo? = null
    private var wasPaused = false
    private var sentLoaded = false

    private val playerListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_BUFFERING -> currentAd?.let { ad ->
                    notifyCallbacks { callback -> callback.onBuffering(ad) }
                }
                Player.STATE_READY -> {
                    if (!sentLoaded && currentAd != null) {
                        sentLoaded = true
                        val ad = currentAd
                        if (ad != null) {
                            notifyCallbacks { callback -> callback.onLoaded(ad) }
                        }
                    }
                }

                Player.STATE_ENDED -> {
                    stopProgressUpdates()
                    currentAd?.let { ad ->
                        notifyCallbacks { callback -> callback.onEnded(ad) }
                    }
                }
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            stopProgressUpdates()
            onPlaybackFailure(error.message ?: "Unable to play the advertisement media.")
            currentAd?.let { ad ->
                notifyCallbacks { callback -> callback.onError(ad) }
            }
        }
    }

    private val progressRunnable = object : Runnable {
        override fun run() {
            val activeAd = currentAd
            if (player.isPlaying && activeAd != null) {
                val progress = adProgressUpdate
                notifyCallbacks { it.onAdProgress(activeAd, progress) }
                mainHandler.postDelayed(this, 250L)
            }
        }
    }

    init {
        player.addListener(playerListener)
    }

    val adProgressUpdate: VideoProgressUpdate
        get() {
            val duration = player.duration
            return if (currentAd == null || duration == C.TIME_UNSET || duration <= 0L) {
                VideoProgressUpdate.VIDEO_TIME_NOT_READY
            } else {
                VideoProgressUpdate(player.currentPosition, duration)
            }
        }

    override fun loadAd(adMediaInfo: AdMediaInfo, adPodInfo: AdPodInfo) {
        currentAd = adMediaInfo
        sentLoaded = false
        wasPaused = false
        try {
            player.setMediaItem(MediaItem.fromUri(adMediaInfo.url.toString()))
            player.prepare()
        } catch (error: Exception) {
            onPlaybackFailure(error.message ?: "Unable to load the advertisement media.")
            notifyCallbacks { callback -> callback.onError(adMediaInfo) }
        }
    }

    override fun playAd(adMediaInfo: AdMediaInfo) {
        currentAd = adMediaInfo
        if (wasPaused) {
            notifyCallbacks { callback -> callback.onResume(adMediaInfo) }
        } else {
            notifyCallbacks { callback -> callback.onPlay(adMediaInfo) }
        }
        wasPaused = false
        player.play()
        startProgressUpdates()
    }

    override fun pauseAd(adMediaInfo: AdMediaInfo) {
        player.pause()
        wasPaused = true
        stopProgressUpdates()
        notifyCallbacks { callback -> callback.onPause(adMediaInfo) }
    }

    override fun stopAd(adMediaInfo: AdMediaInfo) {
        player.stop()
        stopProgressUpdates()
        notifyCallbacks { callback -> callback.onEnded(adMediaInfo) }
        currentAd = null
    }

    override fun release() {
        player.stop()
        player.clearMediaItems()
        stopProgressUpdates()
        currentAd = null
        sentLoaded = false
    }

    override fun addCallback(callback: VideoAdPlayer.VideoAdPlayerCallback) {
        callbacks += callback
    }

    override fun removeCallback(callback: VideoAdPlayer.VideoAdPlayerCallback) {
        callbacks -= callback
    }

    override fun getAdProgress(): VideoProgressUpdate = adProgressUpdate

    override fun getVolume(): Int = (player.volume.coerceIn(0f, 1f) * 100f).roundToInt()

    fun dispose() {
        release()
        player.removeListener(playerListener)
        player.release()
        callbacks.clear()
    }

    private fun startProgressUpdates() {
        stopProgressUpdates()
        mainHandler.post(progressRunnable)
    }

    private fun stopProgressUpdates() {
        mainHandler.removeCallbacks(progressRunnable)
    }

    private inline fun notifyCallbacks(
        action: (VideoAdPlayer.VideoAdPlayerCallback) -> Unit,
    ) {
        callbacks.toList().forEach(action)
    }
}
