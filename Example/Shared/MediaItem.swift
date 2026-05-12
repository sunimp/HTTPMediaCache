//
//  MediaItem.swift
//  HTTPMediaCacheExample
//
//  Created by Sun on 2026/5/9.
//

import Foundation

struct MediaItem: Equatable {
    enum Format: Equatable {
        case mp3
        case aac
        case wav
        case flac
        case ogg
        case mp4
        case mov
        case hls

        var title: String {
            switch self {
            case .mp3:
                return "MP3"
            case .aac:
                return "AAC"
            case .wav:
                return "WAV"
            case .flac:
                return "FLAC"
            case .ogg:
                return "OGG"
            case .mp4:
                return "MP4"
            case .mov:
                return "MOV"
            case .hls:
                return "HLS"
            }
        }
    }

    enum Category: CaseIterable, Equatable {
        case appleMedia
        case publicMedia

        var title: String {
            switch self {
            case .appleMedia:
                return "Apple Media"
            case .publicMedia:
                return "Public Media"
            }
        }
    }

    let title: String
    let url: URL
    let format: Format
    let category: Category
    let usesAirPlayProxy: Bool
}

extension MediaItem {
    static let samples: [MediaItem] = {
        var samples = [
            MediaItem(
                title: "HEVC + Dolby Vision",
                url: makeURL("https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8"),
                format: .hls,
                category: .appleMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "BipBop (fMP4)",
                url: makeURL("https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"),
                format: .hls,
                category: .appleMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "BipBop (TS)",
                url: makeURL("https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"),
                format: .hls,
                category: .appleMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "BipBop 16:9",
                url: makeURL("https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"),
                format: .hls,
                category: .appleMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "BipBop (HEVC)",
                url: makeURL("https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8"),
                format: .hls,
                category: .appleMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "iPad Pro Feature",
                url: makeURL("https://images.apple.com/media/cn/ipad-pro/2017/43c41767_0723_4506_889f_0180acc13482/films/feature/ipad-pro-feature-cn-20170605_640x360h.mp4"),
                format: .mp4,
                category: .appleMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "Sintel Trailer",
                url: makeURL("https://media.w3.org/2010/05/sintel/trailer.mp4"),
                format: .mp4,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "Sample MP3",
                url: makeURL("https://sample.add.sh/sounds/sample.mp3"),
                format: .mp3,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "Sample AAC",
                url: makeURL("https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/test-audio.aac"),
                format: .aac,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "Sample WAV",
                url: makeURL("https://sample.add.sh/sounds/sample.wav"),
                format: .wav,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "Sample FLAC",
                url: makeURL("https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/test-audio.flac"),
                format: .flac,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
        ]
        #if os(macOS)
            samples.append(
                MediaItem(
                    title: "Sample OGG",
                    url: makeURL("https://sample.add.sh/sounds/sample.ogg"),
                    format: .ogg,
                    category: .publicMedia,
                    usesAirPlayProxy: false
                )
            )
        #endif
        samples.append(contentsOf: [
            MediaItem(
                title: "Sample MOV",
                url: makeURL("https://sample.add.sh/movies/sample.mov"),
                format: .mov,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "Big Buck Bunny",
                url: makeURL("https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"),
                format: .hls,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
            MediaItem(
                title: "Tears of Steel",
                url: makeURL("https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8"),
                format: .hls,
                category: .publicMedia,
                usesAirPlayProxy: false
            ),
        ])
        return samples
    }()

    static func samples(in category: Category) -> [MediaItem] {
        samples.filter { $0.category == category }
    }

    private static func makeURL(_ string: String) -> URL {
        URL(string: string)!
    }
}
