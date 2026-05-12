//
//  PlayerWindowController.swift
//  HTTPMediaCacheMacExample
//
//  Created by Sun on 2026/5/11.
//

import AVKit

final class PlayerWindowController: NSWindowController {
    private let mediaURL: URL
    private let playerView = AVPlayerView()

    init(url: URL, title: String) {
        mediaURL = url
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        super.init(window: window)
        configurePlayerView(in: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configurePlayerView(in window: NSWindow) {
        let contentView = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        window.contentView = contentView

        playerView.frame = contentView.bounds
        playerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        playerView.player = AVPlayer(url: mediaURL)
        playerView.player?.play()
    }

    deinit {
        playerView.player?.currentItem?.asset.cancelLoading()
        playerView.player?.currentItem?.cancelPendingSeeks()
        playerView.player?.cancelPendingPrerolls()
    }
}
