//
//  PlayerViewController.swift
//  Podest
//
//  Created by Michael on 3/9/17.
//  Copyright © 2017 Michael Nisi. All rights reserved.
//

import UIKit
import FeedKit
import os.log

private let log = OSLog.disabled

class PlayerViewController: UIViewController,
Navigator, PlaybackControlDelegate {

  // MARK: Outlets

  @IBOutlet weak var doneButton: UIButton!
  @IBOutlet var heroImage: UIImageView!
  @IBOutlet weak var titleButton: UIButton!
  @IBOutlet weak var subtitleLabel: UILabel!
  @IBOutlet weak var playSwitch: PlaySwitch!
  @IBOutlet weak var backwardButton: UIButton!
  @IBOutlet weak var forwardButton: UIButton!
  @IBOutlet weak var episode: UIStackView!
  
  // MARK: - Actions

  @IBAction func doneTouchUpInside(_ sender: Any) {
    navigationDelegate?.hideNowPlaying(animated: true, completion: nil)
  }

  @IBAction func playSwitchValueChanged(_ sender: PlaySwitch) {
    guard let entry = self.entry else {
      return
    }

    guard sender.isOn else {
      navigationDelegate?.pause()
      return
    }

    navigationDelegate?.play(entry)
  }

  @IBAction func backwardTouchUpInside(_ sender: Any) {
    Podest.playback.backward()
  }

  @IBAction func forwardTouchUpInside(_ sender: Any) {
    Podest.playback.forward()
  }

  @IBAction func titleTouchUpInside(_ sender: Any) {
    navigationDelegate?.show(entry: entry!)
  }

  // MARK: - Internals

  private var needsUpdate = false {
    didSet {
      if needsUpdate {
        DispatchQueue.main.async { [weak self] in
          self?.view?.setNeedsLayout()
        }
      }
    }
  }

  internal var entry: Entry? {
    didSet {
      needsUpdate = entry != oldValue || needsUpdate
    }
  }

  internal var isPlaying: Bool = false {
    didSet {
      playSwitch?.isOn = isPlaying
    }
  }
  
  var isBackwardable: Bool = true {
    didSet {
      backwardButton?.isEnabled = isBackwardable
    }
  }
  
  var isForwardable: Bool = true {
    didSet {
      forwardButton?.isEnabled = isForwardable
    }
  }

  // MARK: - Navigator

  var navigationDelegate: ViewControllers?

  // MARK: - Swiping

  var swipe: UISwipeGestureRecognizer!

  @objc func onSwipe(sender: UISwipeGestureRecognizer) {
    os_log("swipe received", log: log, type: .debug)

    switch sender.state {
    case .ended:
      navigationDelegate?.hideNowPlaying(animated: true, completion: nil)
    case .began, .changed, .cancelled, .failed, .possible:
      break
    }
  }

  private var isLandscape: Bool {
    return traitCollection.containsTraits(
      in: UITraitCollection(verticalSizeClass: .compact))
  }

  private func configureSwipe() {
    swipe.direction = isLandscape ? .right : .down
  }

  // MARK: - Image Loading

  private var needsImage = false

  private func loadImage() {
    guard let entry = self.entry else {
      return
    }

    Podest.images.loadImage(
      representing: entry,
      into: heroImage,
      options: FKImageLoadingOptions(
        fallbackImage: UIImage.init(named: "Oval"),
        quality: .high,
        isDirect: false
      )
    )
  }

  // MARK: - UIViewController

  override func viewDidLoad() {
    super.viewDidLoad()

    titleButton.titleLabel?.numberOfLines = 2
    titleButton.titleLabel?.textAlignment = .center

    // Not rendering nicely in IB if applied there.
    subtitleLabel.numberOfLines = 2

    playSwitch.isExclusiveTouch = true

    swipe = UISwipeGestureRecognizer(target: self, action: #selector(onSwipe))
    view.addGestureRecognizer(swipe)
  }


  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    guard needsImage else {
      return
    }

    loadImage()
    needsImage = false
  }

  override func viewWillLayoutSubviews() {
    defer {
      super.viewWillLayoutSubviews()
    }

    guard needsUpdate else {
      return
    }

    guard let entry = self.entry else {
      fatalError("player view controller: entry required")
    }

    UIView.performWithoutAnimation {
      titleButton.setTitle(entry.title, for: .normal)
    }

    subtitleLabel.text = entry.feedTitle

    playSwitch.isOn = isPlaying
    forwardButton.isEnabled = Podest.userQueue.isForwardable
    backwardButton.isEnabled = Podest.userQueue.isBackwardable

    // Only allowing image reloading after view did appear.
    needsImage = shouldReloadImage && true
    
    needsUpdate = false
  }

  private var shouldReloadImage = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    configureSwipe()
    loadImage()
    shouldReloadImage = true
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    shouldReloadImage = false
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    configureSwipe()
  }

  // MARK: - UIStateRestoring

  override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
  }

  override func decodeRestorableState(with coder: NSCoder) {
    super.decodeRestorableState(with: coder)
  }

}


