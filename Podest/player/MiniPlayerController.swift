//
//  MiniPlayerController.swift
//  Podest
//
//  Created by Michael on 3/20/17.
//  Copyright © 2017 Michael Nisi. All rights reserved.
//

import AVFoundation
import AVKit
import FeedKit
import Foundation
import UIKit
import os.log
import Playback
import Ola

private let log = OSLog.disabled

/// The minimized AV player.
final class MiniPlayerController: SomePlayerViewController,
Navigator, PlaybackControlDelegate {

  private struct FetchEntryResult {
    let entry: Entry?
    let error: Error?
  }

  private func fetchEntry(at locator: EntryLocator) {
    let locators = [locator.including]
    var result: FetchEntryResult?
    let animated = !isRestoring

    Podest.browser.entries(locators, entriesBlock: {
      error, entries in
      result = FetchEntryResult(entry: entries.first, error: error)
    }) { [weak self] error in
      guard error == nil, result?.error == nil, let entry = result?.entry else {
        let er = result?.error ?? error ??
          FeedKitError.missingEntries(locators: locators)

        os_log("could not fetch entry: %{public}@",
               log: log, type: .error, er as CVarArg)

        // We’re just a mini-player, we don’t know what to do.
        return DispatchQueue.main.async { [weak self] in
          if let me = self {
            me.navigationDelegate?.viewController(me, error: er)
          }
        }
      }

      DispatchQueue.main.async { [weak self] in
        self?.entry = entry
        self?.navigationDelegate?.showMiniPlayer(animated)
        self?.isRestoring = false
      }
    }
  }

  var locator: EntryLocator? {
    didSet {
      guard let loc = locator, loc != oldValue, loc.guid != entry?.guid else {
        return
      }
      fetchEntry(at: loc)
    }
  }

  /// We don’t have to update while the main player is being used.
  private var shouldUpdate: Bool {
    return !(navigationDelegate?.isPlayerPresented ?? false)
  }

  private var needsUpdate = false {
    didSet {
      if shouldUpdate, needsUpdate {
        DispatchQueue.main.async { [weak self] in
          self?.viewIfLoaded?.setNeedsLayout()
        }
      }
    }
  }

  private var renderedGUID: EntryGUID?

  /// The current playback entry, playing or paused. If we intend to set this
  /// from different threads, this needs to be serialized. Setting this may also
  /// enqueue the entry.
  var entry: Entry? {
    didSet {
      needsUpdate = self.entry != oldValue || self.entry?.guid != renderedGUID

      guard needsUpdate, let entry = self.entry else {
        return
      }

      locator = EntryLocator(entry: entry)
      view.isHidden = false

      Podest.userQueue.enqueue(entries: [entry]) { enqueued, error in
        if let er = error {
          os_log("enqueue warning: %{public}@", type: .debug, er as CVarArg)
        }
      }
    }
  }

  internal var isPlaying = false {
    didSet {
      // Doing this directly for simpler view updating.
      playSwitch.isOn = isPlaying
    }
  }

  // MARK: - UIStateRestoring

  override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)

    guard locator != nil else {
      let keys = ["guid", "url", "since", "title"]
      for key in keys {
        coder.encode(nil, forKey: key)
      }
      return
    }

    locator?.encode(with: coder)
  }

  private var isRestoring = false

  override func decodeRestorableState(with coder: NSCoder) {
    isRestoring = true
    locator = EntryLocator(coder: coder)

    super.decodeRestorableState(with: coder)
  }

  // MARK: - Navigator

  var navigationDelegate: ViewControllers?

  var swipe: UISwipeGestureRecognizer!

  // MARK: - More Members

  @IBOutlet var titleLabel: UILabel!

  @IBOutlet var hero: UIImageView!

  @IBOutlet var playSwitch: PlaySwitch!

  var matte: UIView?

  @IBAction func onPlaySwitchValueChanged(_ sender: PlaySwitch) {
    guard let entry = self.entry else {
      return
    }

    if sender.isOn {
      navigationDelegate?.play(entry)
    } else {
      navigationDelegate?.pause()
    }
  }

  var blurEffectView: UIVisualEffectView!

  fileprivate func insertEffect(below subview: UIView) {
    let blurEffect = UIBlurEffect(style: .extraLight)

    blurEffectView = UIVisualEffectView(effect: blurEffect)
    blurEffectView.frame = view.bounds
    blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    view.insertSubview(blurEffectView, belowSubview: subview)
  }

  // MARK: - UIViewController

  override func viewDidLoad() {
    super.viewDidLoad()

    view.isHidden = true

    view.sendSubviewToBack(titleLabel)
    insertEffect(below: titleLabel)

    playSwitch.isExclusiveTouch = true

    let touchDown = UILongPressGestureRecognizer(
      target: self, action: #selector(onTouchDown))
    touchDown.minimumPressDuration = 0
    touchDown.cancelsTouchesInView = false
    view.addGestureRecognizer(touchDown)

    swipe = UISwipeGestureRecognizer(target: self, action: #selector(onSwipe))
    swipe.delegate = self
    view.addGestureRecognizer(swipe)

    let edgePan = UIScreenEdgePanGestureRecognizer(
      target: self, action: #selector(onEdgePan))
    edgePan.edges = .bottom
    edgePan.delegate = self
    view.addGestureRecognizer(edgePan)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    configureSwipe()
  }

  private func loadImage(representing entry: Entry) {
    let opts = FKImageLoadingOptions(
      fallbackImage: UIImage(named: "Oval"),
      quality: .high,
      isDirect: true
    )

    Podest.images.loadImage(representing: entry, into: hero, options: opts)
  }

  override func viewWillLayoutSubviews() {
    defer {
      super.viewWillLayoutSubviews()
    }

    guard needsUpdate else { return }

    guard let entry = self.entry else {
      fatalError("entry cannot be nil")
    }

    titleLabel.text = entry.title
    playSwitch.isOn = isPlaying
    renderedGUID = entry.guid

    loadImage(representing: entry)

    needsUpdate = false
  }

  override
  func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    configureSwipe()
  }

}

// MARK: - UITapGestureRecognizer

extension MiniPlayerController {

  private func showMatte() {
    let sv = blurEffectView.contentView

    let v = UIView(frame: sv.frame)
    let g = CGFloat(0.92)
    v.backgroundColor = UIColor(red: g, green: g, blue: g, alpha: 1)

    sv.addSubview(v)

    matte = v
  }

  private func hideMatte() {
    matte?.removeFromSuperview()
  }

  @objc func onTouchDown(sender: UILongPressGestureRecognizer) {
    os_log("press received: %i", log: log, type: .debug, sender.state.rawValue)

    func isPlaySwitchHit() -> Bool {
      let p = sender.location(in: view)
      return view!.hitTest(p, with: nil) == playSwitch
    }

    switch sender.state {
    case .began:
      guard !isPlaySwitchHit() else {
        return
      }

      showMatte()

    case .cancelled, .failed:
      hideMatte()

    case .ended:
      hideMatte()

      guard let entry = self.entry,
        !isPlaySwitchHit(),
        !playSwitch.isTracking,
        !playSwitch.isCancelled else {
        playSwitch.isCancelled = false
        return
      }

      let p = sender.location(in: view)
      let insets = UIEdgeInsets(top: 5, left: 5, bottom: 10, right: 10)
      let hitArea = view.frame.inset(by: insets)

      guard hitArea.contains(p) else {
        return
      }

      navigationDelegate?.showNowPlaying(entry: entry)

    case .possible, .changed:
      break
    }
  }

}

// MARK: - UISwipeGestureRecognizer

extension MiniPlayerController {

  @objc func onSwipe(sender: UISwipeGestureRecognizer) {
    os_log("swipe received", log: log, type: .debug)

    guard let entry = self.entry, !playSwitch.isTracking else {
      return
    }

    switch sender.state {
    case .ended:
      navigationDelegate?.showNowPlaying(entry: entry)
    case .began, .changed, .cancelled, .failed, .possible:
      break
    }
  }

  /// Configures swipe for device orientation.
  private func configureSwipe() {
    swipe.direction = isLandscape ? .left : .up
  }

}

// MARK: - UIScreenEdgePanGestureRecognizer

extension MiniPlayerController {

  @objc func onEdgePan(sender: UIScreenEdgePanGestureRecognizer) {
    os_log("edge pan received", log: log, type: .debug)
  }

}
