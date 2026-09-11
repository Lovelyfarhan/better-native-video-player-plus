import AVFoundation
import AVKit
import GoogleInteractiveMediaAds

/// Bridges the provider-neutral advertisement contract to Google's iOS IMA
/// client-side SDK. The content AVPlayer remains owned by VideoPlayerView;
/// IMA owns only ad scheduling and its overlay playback.
final class ImaAdvertisementBridge: NSObject, IMAAdsLoaderDelegate, IMAAdsManagerDelegate {
    private weak var contentPlayer: AVPlayer?
    private weak var displayView: UIView?
    private weak var viewController: UIViewController?
    private let emitEvent: ([String: Any]) -> Void

    private var contentPlayhead: IMAAVPlayerContentPlayhead?
    private var adsLoader: IMAAdsLoader?
    private var adsManager: IMAAdsManager?
    private var adDisplayContainer: IMAAdDisplayContainer?
    private var adContainer: UIView?
    private var contentWasPlayingBeforeAd = false
    private var shouldResumeContentAfterAd = false
    private var adStartRequested = false
    private var isPostRoll = false
    private var isVmap = false
    private var resumeContentOnError = true
    private var requestInFlight = false
    private var isDestroyed = false

    init(
        contentPlayer: AVPlayer,
        displayView: UIView,
        viewController: UIViewController,
        emitEvent: @escaping ([String: Any]) -> Void
    ) {
        self.contentPlayer = contentPlayer
        self.displayView = displayView
        self.viewController = viewController
        self.emitEvent = emitEvent
        super.init()
    }

    func handleMethodCall(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) -> Bool {
        guard call.method.hasPrefix("advertisement") else { return false }

        switch call.method {
        case "advertisementInitialize":
            initialize(configuration: call.arguments)
            result(nil)
        case "advertisementRequestAds":
            requestAds()
            result(nil)
        case "advertisementContentComplete":
            adsLoader?.contentComplete()
            result(nil)
        case "advertisementStart":
            adsManager?.start()
            result(nil)
        case "advertisementPause":
            adsManager?.pause()
            result(nil)
        case "advertisementSkip":
            adsManager?.skip()
            result(nil)
        case "advertisementResume":
            adsManager?.resume()
            result(nil)
        case "advertisementStop":
            adsManager?.destroy()
            adsManager = nil
            hideAdContainer()
            resumeContentAfterAd()
            result(nil)
        case "advertisementDestroy":
            destroy()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
        return true
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true

        contentWasPlayingBeforeAd = false
        shouldResumeContentAfterAd = false
        adStartRequested = false
        adsManager?.delegate = nil
        adsManager?.destroy()
        adsManager = nil
        adsLoader?.delegate = nil
        adsLoader = nil
        contentPlayhead = nil
        adDisplayContainer = nil
        requestTag = nil
        isPostRoll = false
        isVmap = false
        requestInFlight = false
        hideAdContainer()
        adContainer?.removeFromSuperview()
        adContainer = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func initialize(configuration arguments: Any?) {
        destroy()
        isDestroyed = false

        guard let arguments = arguments as? [String: Any],
              let rawConfiguration = arguments["adConfiguration"] as? [String: Any],
              (rawConfiguration["enabled"] as? Bool ?? true),
              let tagURL = rawConfiguration["adTagUrl"] as? String,
              !tagURL.isEmpty,
              let contentPlayer,
              let displayView,
              let viewController
        else {
            return
        }

        let adContainer = UIView(frame: displayView.bounds)
        adContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        adContainer.isHidden = true
        displayView.addSubview(adContainer)
        self.adContainer = adContainer

        contentPlayhead = IMAAVPlayerContentPlayhead(avPlayer: contentPlayer)
        let settings = IMASettings()
        adsLoader = IMAAdsLoader(settings: settings)
        adsLoader?.delegate = self

        adDisplayContainer = IMAAdDisplayContainer(
            adContainer: adContainer,
            viewController: viewController,
            companionSlots: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentDidFinishPlaying(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )

        requestTag = tagURL
        isPostRoll = (rawConfiguration["adBreaks"] as? [[String: Any]])?.contains {
            ($0["type"] as? String) == "postRoll"
        } == true
        isVmap = (rawConfiguration["tagType"] as? String) == "vmap"
        resumeContentOnError = rawConfiguration["resumeContentOnError"] as? Bool ?? true
    }

    private var requestTag: String?

    private func requestAds() {
        guard !requestInFlight else { return }
        guard let requestTag,
              let adsLoader,
              let adDisplayContainer,
              let contentPlayhead
        else {
            handleAdvertisementFailure(code: "IMA_NOT_INITIALIZED", message: "IMA is not initialized.")
            return
        }

        pauseContentForAd()
        adStartRequested = false
        let request = IMAAdsRequest(
            adTagUrl: requestTag,
            adDisplayContainer: adDisplayContainer,
            contentPlayhead: contentPlayhead,
            userContext: nil
        )
        shouldResumeContentAfterAd = !isPostRoll
        requestInFlight = true
        emitEvent(["adEventType": "requestStarted"])
        adsLoader.requestAds(with: request)
    }

    @objc private func contentDidFinishPlaying(_ notification: Notification) {
        guard notification.object as? AVPlayerItem === contentPlayer?.currentItem else {
            return
        }
        adsLoader?.contentComplete()
    }

    func adsLoader(_ loader: IMAAdsLoader, adsLoadedWith data: IMAAdsLoadedData) {
        adsManager?.delegate = nil
        adsManager?.destroy()
        adsManager = data.adsManager
        adsManager?.delegate = self
        adsManager?.initialize(with: IMAAdsRenderingSettings())
    }

    func adsLoader(_ loader: IMAAdsLoader, failedWith adErrorData: IMAAdLoadingErrorData) {
        handleAdvertisementFailure(code: "IMA_AD_LOAD_ERROR", message: adErrorData.adError.message)
    }

    func adsManager(_ adsManager: IMAAdsManager, didReceive event: IMAAdEvent) {
        let rawType = String(describing: event.type).uppercased()
        let eventType: String
        switch rawType {
        case "LOADED":
            if !adStartRequested {
                adStartRequested = true
                adsManager.start()
            }
            eventType = "breakReady"
        case "STARTED": eventType = "adStarted"
        case "FIRST_QUARTILE": eventType = "firstQuartile"
        case "MIDPOINT": eventType = "midpoint"
        case "THIRD_QUARTILE": eventType = "thirdQuartile"
        case "AD_BREAK_STARTED": eventType = "breakStarted"
        case "PAUSED": eventType = "adPaused"
        case "RESUMED": eventType = "adResumed"
        case "SKIPPED": eventType = "adSkipped"
        case "COMPLETE", "COMPLETED": eventType = "adCompleted"
        case "AD_BREAK_ENDED": eventType = "breakCompleted"
        case "ALL_ADS_COMPLETED": eventType = "allAdsCompleted"
        case "AD_PROGRESS": eventType = "adProgress"
        case "CLICKED", "TAPPED": eventType = "clicked"
        default: eventType = rawType
        }
        var data: [String: Any] = ["adEventType": eventType]
        if let ad = event.ad {
            data["metadata"] = [
                "adId": ad.adId,
                "creativeId": ad.creativeID,
                "adSystem": ad.adSystem,
                "title": ad.adTitle,
                "advertiserName": ad.advertiserName,
                "durationMs": Int(ad.duration * 1000.0),
                "isSkippable": ad.isSkippable,
                "skipTimeOffsetMs": ad.skipTimeOffset >= 0
                    ? Int(ad.skipTimeOffset * 1000.0)
                    : -1,
            ]
        }
        if rawType == "ALL_ADS_COMPLETED" {
            requestInFlight = false
        }
        emitEvent(data)
    }

    func adsManager(_ adsManager: IMAAdsManager, didReceive error: IMAAdError) {
        handleAdvertisementFailure(code: "IMA_AD_ERROR", message: error.message)
    }

    func adsManagerDidRequestContentPause(_ adsManager: IMAAdsManager) {
        pauseContentForAd()
        showAdContainer()
    }

    func adsManagerDidRequestContentResume(_ adsManager: IMAAdsManager) {
        hideAdContainer()
        resumeContentAfterAd()
    }

    private func emitError(code: String, message: String) {
        emitEvent([
            "adEventType": "error",
            "error": ["code": code, "message": message],
        ])
    }

    private func handleAdvertisementFailure(code: String, message: String) {
        requestInFlight = false
        emitError(code: code, message: message)
        hideAdContainer()
        adsManager?.delegate = nil
        adsManager?.destroy()
        adsManager = nil
        if resumeContentOnError {
            resumeContentAfterAd()
        } else {
            contentWasPlayingBeforeAd = false
            shouldResumeContentAfterAd = false
        }
    }

    private func showAdContainer() {
        adContainer?.isHidden = false
    }

    private func pauseContentForAd() {
        guard let contentPlayer else { return }
        if !contentWasPlayingBeforeAd {
            contentWasPlayingBeforeAd = contentPlayer.rate > 0
        }
        contentPlayer.pause()
    }

    private func hideAdContainer() {
        adContainer?.isHidden = true
    }

    private func resumeContentAfterAd() {
        if contentWasPlayingBeforeAd || shouldResumeContentAfterAd {
            contentPlayer?.play()
        }
        contentWasPlayingBeforeAd = false
        shouldResumeContentAfterAd = false
    }
}