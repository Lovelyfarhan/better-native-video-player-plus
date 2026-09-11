import AVFoundation
import Foundation

/// Handles DRM (Digital Rights Management) for protected content playback.
/// Supports FairPlay Streaming and AES-128 (Standard HLS Encryption).
///
/// When a custom AES-128 key (32-character hex string = 16 bytes) is supplied
/// via drmConfig["key"], the key URI present in the .m3u8 playlist is ignored
/// and the provided key is returned through AVAssetResourceLoaderDelegate.
class VideoPlayerDrmHandler: NSObject {
    private var contentKeySession: AVContentKeySession?
    private var drmConfig: [String: Any]
    private var certificateData: Data?
    private var certificateUrl: URL?
    private var licenseUrl: URL?
    private var licenseHeaders: [String: String]?

    /// Custom AES-128 key (exactly 16 bytes) when provided by Flutter.
    private var customAesKey: Data?

    init(drmConfig: [String: Any]) {
        self.drmConfig = drmConfig

        if let licenseUrlString = drmConfig["licenseUrl"] as? String {
            self.licenseUrl = URL(string: licenseUrlString)
        }

        if let certificateUrlString = drmConfig["certificateUrl"] as? String {
            self.certificateUrl = URL(string: certificateUrlString)
        }

        if let headers = drmConfig["headers"] as? [String: String] {
            self.licenseHeaders = headers
        }

        // Parse optional custom AES-128 key (32-char hex → 16 bytes)
        if let keyHex = drmConfig["key"] as? String,
           keyHex.count == 32,
           let keyData = Data(hexString: keyHex) {
            self.customAesKey = keyData
            npLog("🔐 DRM: Custom AES-128 key loaded (\(keyData.count) bytes)")
        }

        super.init()
    }

    /// Sets up DRM for the given asset.
    func setupDRM(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let drmType = drmConfig["type"] as? String else {
            completion(false, NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "DRM type not specified"]))
            return
        }

        let drmTypeLower = drmType.lowercased()

        if drmTypeLower == "aes-128" {
            if customAesKey != nil {
                // Install resource loader so we can intercept key requests
                // and ignore the key URI that appears in the playlist.
                asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "com.better_native_video_player.aes128"))
                npLog("🔐 DRM: AES-128 with custom key – resource loader installed (playlist key URI will be ignored)")
            } else {
                npLog("🔐 DRM: AES-128 – using standard HLS key download from playlist")
            }
            completion(true, nil)
            return
        }

        if drmTypeLower == "fairplay" {
            setupFairPlay(asset: asset, completion: completion)
        } else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Unsupported DRM type: \(drmType)"])
            completion(false, error)
        }
    }

    // MARK: - FairPlay

    private func setupFairPlay(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let licenseUrl = licenseUrl else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "License URL is required for FairPlay"])
            completion(false, error)
            return
        }

        npLog("🔐 DRM: Setting up FairPlay - License URL: \(licenseUrl.absoluteString)")

        contentKeySession = AVContentKeySession(keySystem: AVContentKeySystem.fairPlayStreaming)

        let delegateQueue = DispatchQueue(label: "com.better_native_video_player.drm")
        contentKeySession?.setDelegate(self, queue: delegateQueue)

        contentKeySession?.addContentKeyRecipient(asset)

        if let certificateUrl = certificateUrl {
            fetchCertificate(url: certificateUrl) { [weak self] success, error in
                if success {
                    npLog("🔐 DRM: Certificate fetched successfully")
                    completion(true, nil)
                } else {
                    npLog("🔐 DRM: Failed to fetch certificate: \(error?.localizedDescription ?? "unknown error")")
                    completion(false, error)
                }
            }
        } else {
            npLog("🔐 DRM: No certificate URL provided, using default FairPlay certificate")
            completion(true, nil)
        }
    }

    private func fetchCertificate(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        npLog("🔐 DRM: Fetching certificate from: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let headers = licenseHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                npLog("🔐 DRM: Certificate fetch error: \(error.localizedDescription)")
                completion(false, error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to fetch certificate: Invalid response"])
                completion(false, error)
                return
            }

            guard let data = data else {
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to fetch certificate: No data"])
                completion(false, error)
                return
            }

            self.certificateData = data
            npLog("🔐 DRM: Certificate fetched successfully (\(data.count) bytes)")
            completion(true, nil)
        }

        task.resume()
    }

    /// Cleans up DRM resources.
    func cleanup() {
        contentKeySession = nil
        certificateData = nil
        customAesKey = nil
        npLog("🔐 DRM: Cleaned up DRM handler")
    }
}

// MARK: - AVContentKeySessionDelegate (FairPlay)

extension VideoPlayerDrmHandler: AVContentKeySessionDelegate {
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        npLog("🔐 DRM: Content key request received")

        guard let licenseUrl = licenseUrl else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "License URL is missing"])
            keyRequest.processContentKeyResponseError(error)
            return
        }

        // Make streaming content key request
        do {
            let spcData = try keyRequest.makeStreamingContentKeyRequestData(
                forApp: certificateData ?? Data(),
                contentIdentifier: keyRequest.identifier as? Data ?? Data(),
                options: nil
            )

            var request = URLRequest(url: licenseUrl)
            request.httpMethod = "POST"
            request.httpBody = spcData
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            if let headers = licenseHeaders {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    npLog("🔐 DRM: License request error: \(error.localizedDescription)")
                    keyRequest.processContentKeyResponseError(error)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let error = NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "License request failed with status code: \(statusCode)"])
                    npLog("🔐 DRM: License request failed: \(error.localizedDescription)")
                    keyRequest.processContentKeyResponseError(error)
                    return
                }

                guard let data = data else {
                    let error = NSError(domain: "VideoPlayerDrmHandler", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "No data in license response"])
                    npLog("🔐 DRM: License response error: \(error.localizedDescription)")
                    keyRequest.processContentKeyResponseError(error)
                    return
                }

                do {
                    let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: data)
                    keyRequest.processContentKeyResponse(keyResponse)
                    npLog("🔐 DRM: License response processed successfully")
                } catch {
                    npLog("🔐 DRM: Error processing license response: \(error.localizedDescription)")
                    keyRequest.processContentKeyResponseError(error)
                }
            }

            task.resume()
        } catch {
            npLog("🔐 DRM: Failed to create SPC data: \(error.localizedDescription)")
            keyRequest.processContentKeyResponseError(error)
        }
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        npLog("🔐 DRM: Persistable content key request received")
        contentKeySession(session, didProvide: keyRequest as AVContentKeyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        npLog("🔐 DRM: Renewing content key request received")
        contentKeySession(session, didProvide: keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest, reason retryReason: String) -> Bool {
        npLog("🔐 DRM: Content key request should retry - reason: \(retryReason)")
        return retryReason.contains("network") || retryReason.contains("timeout")
    }
}

// MARK: - AVAssetResourceLoaderDelegate (custom AES-128 key)

extension VideoPlayerDrmHandler: AVAssetResourceLoaderDelegate {

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let customKey = customAesKey else {
            // No custom key → let AVPlayer handle the request normally.
            return false
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading(with: NSError(domain: "VideoPlayerDrmHandler", code: -2,
                                                       userInfo: [NSLocalizedDescriptionKey: "Missing data request"]))
            return true
        }

        // Serve the custom 16-byte key. This intentionally ignores the
        // key URI that appears in the #EXT-X-KEY tag of the playlist.
        dataRequest.respond(with: customKey)

        if let contentInfo = loadingRequest.contentInformationRequest {
            contentInfo.contentType = "application/octet-stream"
            contentInfo.contentLength = Int64(customKey.count)
            contentInfo.isByteRangeAccessSupported = false
        }

        loadingRequest.finishLoading()
        npLog("🔐 DRM: Served custom AES-128 key (\(customKey.count) bytes) – playlist key URI ignored")
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        npLog("🔐 DRM: Resource loader request cancelled")
    }
}

// MARK: - Hex helper

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
