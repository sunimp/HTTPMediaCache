//
//  PlayerViewController.swift
//  HTTPMediaCacheiOSExample
//
//  Created by Sun on 2026/5/9.
//

import AVKit

final class PlayerViewController: AVPlayerViewController {
    private let mediaURL: URL

    init(url: URL) {
        mediaURL = url
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        player = AVPlayer(url: mediaURL)
        player?.play()
    }

    deinit {
        player?.currentItem?.asset.cancelLoading()
        player?.currentItem?.cancelPendingSeeks()
        player?.cancelPendingPrerolls()
    }
}
