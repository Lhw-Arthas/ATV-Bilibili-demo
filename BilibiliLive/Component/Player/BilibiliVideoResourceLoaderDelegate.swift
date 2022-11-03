//
//  CustomPlaylistDelegate.swift
//  MPEGDASHAVPlayerDemo
//
//  Created by yicheng on 2022/08/20.
//  Copyright © 2022 yicheng. All rights reserved.
//

import AVFoundation
import SwiftyJSON
import UIKit

class BilibiliVideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    enum URLs {
        static let customScheme = "atv"
        static let customPrefix = customScheme + "://"
        static let play = customPrefix + "play"
        static let subtitles = customPrefix + "subtitles"
    }

    private var audioPlaylist = ""
    private var videoPlaylist = ""
    private var backupVideoPlaylist = ""
    private var masterPlaylist = ""

    private let badRequestErrorCode = 455

    private var playlists = [String]()
    private var subtitlesLists = [String]()
    private var hasAudioInMasterListAdded = false
    private(set) var playInfo: VideoPlayURLInfo?

    var infoDebugText: String {
        let videoCodec = playInfo?.dash.video.map({ $0.codecs }).prefix(5).joined(separator: ",") ?? "nil"
        let audioCodec = playInfo?.dash.audio.map({ $0.codecs }).prefix(5).joined(separator: ",") ?? "nil"
        return "video codecs: \(videoCodec), audio: \(audioCodec)"
    }

    let videoCodecBlackList = ["avc1.640034", "hev1.2.4.L153.90"] // high 5.2 is not supported

    private func reset() {
        playlists.removeAll()
        masterPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:6

        """
    }

    private func addVideoPlayBackInfo(codec: String, width: Int, height: Int, frameRate: String, bandwidth: Int, duration: Int, url: String, sar: String) {
        guard !videoCodecBlackList.contains(codec) else { return }
        let content = """
        #EXT-X-STREAM-INF:AUDIO="audio",CODECS="\(codec)",RESOLUTION=\(width)x\(height),FRAME-RATE=\(frameRate),BANDWIDTH=\(bandwidth),SUBTITLES="subs"
        \(URLs.customPrefix)\(playlists.count)

        """
        masterPlaylist.append(content)

        let playList = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:\(duration)
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXTINF:\(duration)
        \(url)
        #EXT-X-MLB-VIDEO-INFO:codecs="\(codec)",width="\(width)",height="\(height)",sar="\(sar)",frame-duration=1
        #EXT-X-MLB-INFO:max-bw=\(bandwidth),duration=\(duration)
        #EXT-X-ENDLIST
        """
        playlists.append(playList)
    }

    private func addAudioPlayBackInfo(codec: String, bandwidth: Int, duration: Int, url: String) {
        let defaultStr = !hasAudioInMasterListAdded ? "YES" : "NO"
        hasAudioInMasterListAdded = true
        let content = """
        #EXT-X-MEDIA:TYPE=AUDIO,DEFAULT=\(defaultStr),GROUP-ID="audio",NAME="Main",URI="\(URLs.customPrefix)\(playlists.count)"

        """
        masterPlaylist.append(content)

        let playList = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:\(duration)
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXTINF:\(duration)
        \(url)
        #EXT-X-MLB-AUDIO-INFO:codecs="\(codec)"
        #EXT-X-MLB-INFO:max-bw=\(bandwidth),duration=\(duration)
        #EXT-X-ENDLIST
        """
        playlists.append(playList)
    }

    private func addSubtitles(subtitles: VideoSubtitles, duration: Int) {
        let content = """
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="\(subtitles.lanDoc)",URI="\(URLs.subtitles)\(subtitlesLists.count)"

        """
        masterPlaylist.append(content)

        let playList = """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(duration)
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:EVENT
        \(URLs.subtitles)\(subtitlesLists.count)
        #EXT-X-ENDLIST
        """
        playlists.append(playList)

        var vttList = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000


        """

        for content in subtitles.content {
            let vtt = """
            \(transToHourMinSec(time: content.from)) --> \(transToHourMinSec(time: content.to)) align:center line:-1
            \(content.content)


            """
            vttList.append(vtt)
        }
        subtitlesLists.append(vttList)
    }

    func transToHourMinSec(time: Float) -> String {
        let allTime = Int(time)
        var hours = 0
        var minutes = 0
        var seconds = 0
        var hoursText = ""
        var minutesText = ""
        var secondsText = ""

        let millSec = Int((time - Float(allTime)) * 1000)

        hours = allTime / 3600
        hoursText = hours > 9 ? "\(hours)" : "0\(hours)"

        minutes = allTime % 3600 / 60
        minutesText = minutes > 9 ? "\(minutes)" : "0\(minutes)"

        seconds = allTime % 3600 % 60
        secondsText = seconds > 9 ? "\(seconds)" : "0\(seconds)"

        return "\(hoursText):\(minutesText):\(secondsText).\(millSec)"
    }

    func setBilibili(info: VideoPlayURLInfo, subtitlesList: [VideoSubtitles]) {
        playInfo = info
        reset()
        var videos = info.dash.video
        if Settings.preferHevc {
            if videos.contains(where: { $0.isHevc }) {
                videos.removeAll(where: { !$0.isHevc })
            }
        }

        for video in videos {
            for url in video.playableURLs {
                addVideoPlayBackInfo(codec: video.codecs, width: video.width, height: video.height, frameRate: video.frame_rate, bandwidth: video.bandwidth, duration: info.dash.duration, url: url, sar: video.sar)
            }
        }

        if Settings.losslessAudio {
            if let audios = info.dash.dolby?.audio {
                for audio in audios {
                    for url in BVideoUrlUtils.sortUrls(base: audio.base_url, backup: audio.backup_url) {
                        addAudioPlayBackInfo(codec: audio.codecs, bandwidth: audio.bandwidth, duration: info.dash.duration, url: url)
                    }
                }
            } else if let audio = info.dash.flac?.audio {
                for url in audio.playableURLs {
                    addAudioPlayBackInfo(codec: audio.codecs, bandwidth: audio.bandwidth, duration: info.dash.duration, url: url)
                }
            }
        }

        for audio in info.dash.audio {
            for url in audio.playableURLs {
                addAudioPlayBackInfo(codec: audio.codecs, bandwidth: audio.bandwidth, duration: info.dash.duration, url: url)
            }
        }

        if subtitlesList.count > 0 {
            for subtitles in subtitlesList {
                addSubtitles(subtitles: subtitles, duration: info.dash.duration)
            }
        }
    }

    private func reportError(_ loadingRequest: AVAssetResourceLoadingRequest, withErrorCode error: Int) {
        loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: error, userInfo: nil))
    }

    private func report(_ loadingRequest: AVAssetResourceLoadingRequest, content: String) {
        if let data = content.data(using: .utf8) {
            loadingRequest.dataRequest?.respond(with: data)
            loadingRequest.finishLoading()
        } else {
            reportError(loadingRequest, withErrorCode: badRequestErrorCode)
        }
    }

    func resourceLoader(_: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool
    {
        guard let scheme = loadingRequest.request.url?.scheme, scheme == URLs.customScheme else {
            return false
        }

        DispatchQueue.main.async {
            self.handleCustomPlaylistRequest(loadingRequest)
        }
        return true
    }
}

private extension BilibiliVideoResourceLoaderDelegate {
    func handleCustomPlaylistRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let customUrl = loadingRequest.request.url?.absoluteString else {
            reportError(loadingRequest, withErrorCode: badRequestErrorCode)
            return
        }

        if customUrl == URLs.play {
            report(loadingRequest, content: masterPlaylist)
            return
        }
        print("handle loading", customUrl)
        if customUrl.hasPrefix(URLs.subtitles) {
            if let index = Int(customUrl.dropFirst(URLs.subtitles.count)) {
                let subtitles = subtitlesLists[index]
                report(loadingRequest, content: subtitles)
                return
            }
        }
        if let index = Int(customUrl.dropFirst(URLs.customPrefix.count)) {
            let playlist = playlists[index]
            print(playlist)
            report(loadingRequest, content: playlist)
            return
        }
        print("handle loading", customUrl)
    }
}

enum BVideoUrlUtils {
    static func sortUrls(base: String, backup: [String]?) -> [String] {
        var urls = [base]
        if let backup {
            urls.append(contentsOf: backup)
        }
        return
            urls.sorted { lhs, rhs in
                let lhsIsPCDN = lhs.contains("szbdyd.com") || lhs.contains("mcdn.bilivideo.cn")
                let rhsIsPCDN = rhs.contains("szbdyd.com") || rhs.contains("mcdn.bilivideo.cn")
                switch (lhsIsPCDN, rhsIsPCDN) {
                case (true, false): return false
                case (false, true): return true
                case (true, true): fallthrough
                case (false, false): return lhs > rhs
                }
            }
    }
}

extension VideoPlayURLInfo.DashInfo.DashMediaInfo {
    var playableURLs: [String] {
        BVideoUrlUtils.sortUrls(base: base_url, backup: backup_url)
    }

    var isHevc: Bool {
        return codecs.starts(with: "hev")
    }
}
