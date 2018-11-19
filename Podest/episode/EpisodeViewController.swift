//
//  EpisodeViewController.swift
//  Podest
//
//  Created by Michael on 2/1/16.
//  Copyright © 2016 Michael Nisi. All rights reserved.
//

import UIKit
import FeedKit
import os.log

private let log = OSLog.disabled

final class EpisodeViewController: UIViewController, EntryProvider, Navigator {

  // MARK: - API

  var locator: EntryLocator? {
    didSet {
      guard locator != oldValue else {
        return
      }
    }
  }
  
  private var entryChanged = false

  var entry: Entry? {
    didSet {
      entryChanged = entry != oldValue
      
      if let e = entry {
        locator = EntryLocator(entry: e)
        updateIsEnqueued()
      }

      viewIfLoaded?.setNeedsLayout()
    }
  }

  /// `true` if this episode is in the queue.
  var isEnqueued: Bool = false {
    didSet {
      guard navigationItem.rightBarButtonItems == nil ||
        isEnqueued != oldValue else {
        return
      }
      
      configureNavigationItem()
    }
  }

  /// Updates the `isEnqueued` property using `enqueued` or the user queue.
  func updateIsEnqueued(using enqueued: Set<EntryGUID>? = nil) -> Void {
    guard let e = entry else {
      return
    }

    guard let guids = enqueued else {
      isEnqueued = Podest.userQueue.contains(entry: e)
      return
    }

    isEnqueued = guids.contains(e.guid)
  }

  /// Returns `true` if neither entry, nor locator have been set.
  var isEmpty: Bool {
    get {
      return entry == nil && locator == nil
    }
  }

  // MARK: - Internals

  @IBOutlet var avatar: UIImageView!

  @IBOutlet var feedButton: UIButton!
  @IBOutlet var updatedLabel: UILabel!
  @IBOutlet var durationLabel: UILabel!
  
  // MARK: Navigator

  /// The **required** navigation delegate.
  var navigationDelegate: ViewControllers?

  // MARK: - UIViewController

  /// Enables us to cancel the fetching entries operation.
  weak private var fetchingEntries: Operation?

  @IBOutlet weak var content: UITextView!

  @objc func selectFeed() {
    guard let url = entry?.feed else {
      fatalError("cannot select undefined feed")
    }
    navigationDelegate?.openFeed(url: url)
  }

  // MARK: State Transitions

  @IBOutlet var scrollView: UIScrollView!

  /// Additionally to `onDrag`, dismissing the keyboard `onTap`.
  @objc func onTap(_ sender: Any) {
    navigationDelegate?.resignSearch()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    
    resetView()

    feedButton.titleLabel?.numberOfLines = 2
    feedButton.addTarget(
      self, action: #selector(selectFeed), for: .touchUpInside)

    if let label = feedButton.titleLabel {
      label.rightAnchor.constraint(equalTo:
        feedButton.rightAnchor).isActive = true
    }

    content.delegate = self

    scrollView.keyboardDismissMode = .onDrag

    let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
    tap.numberOfTapsRequired = 1
    view.addGestureRecognizer(tap)

    self.navigationItem.largeTitleDisplayMode = .never
  }

  private func showMessage(_ msg: NSAttributedString) {
    os_log("episode: showing message", log: log, type: .debug)
    let nib = UINib(nibName: "ListBackgroundView", bundle: Bundle.main)
    guard let messageView = nib.instantiate(withOwner: nil)
      .first as? ListBackgroundView else {
      fatalError("Failed to initiate view")
    }
    messageView.frame = view.frame
    view.addSubview(messageView)

    messageView.attributedText = msg
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    guard entry == nil else {
      return updateIsEnqueued()
    }
    
    guard let locator = self.locator else {
      return configureView()
    }

    fetchingEntries?.cancel()

    var acc = [Entry]()

    fetchingEntries = Podest.browser.entries(
      [locator.including], entriesBlock: { error, entries in
      if let er = error {
        os_log("entry block error: %{public}@", log: log, type: .error,
               String(describing: er))
      }
      DispatchQueue.main.async {
        acc.append(contentsOf: entries)
      }
    }) { [weak self] error in
      guard error == nil else {
        if let msg = StringRepository.message(describing: error!) {
          DispatchQueue.main.async {
            self?.showMessage(msg)
          }
        }
        return
      }
      
      // At launch, during state restoration, the user library might not be
      // completely synchronized yet, so we sync and wait before configuring
      // the navigation item.
      Podest.userLibrary.synchronize { error in
        if let er = error {
          switch er {
          case QueueingError.outOfSync(let queue, let guids):
            os_log("** out of sync: ( queue: %i, guids: %i )",
                   log: log, type: .debug, queue, guids)
          default:
            fatalError("probably a database error: \(er)")
          }
        }

        // Queue and guids don’t have to be in sync for checking if this entry
        // in enqueued.

        DispatchQueue.main.async { [weak self] in
          self?.isEnqueued = Podest.userQueue.contains(entry: acc.first!)
        }
      }

      DispatchQueue.main.async {
        guard let e = acc.first else {
          let q = DispatchQueue.global(qos: .userInteractive)
          return q.async { [weak self] in
            let title = self?.title ?? ""
            let message = StringRepository.noEpisode(with: title)
            DispatchQueue.main.async { [weak self] in
              self?.showMessage(message)
            }
          }
        }
        
        self?.entry = e
      }

    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)

    fetchingEntries?.cancel()
    content?.isSelectable = false
  }
  
  override func traitCollectionDidChange(
    _ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    os_log("resigning first responder", log: log)
    content?.resignFirstResponder()
  }
  
  private func configureView() -> Void {
    assert(viewIfLoaded != nil)

    guard let entry = self.entry else {
      return showMessage(StringRepository.noEpisodeSelected())
    }
    
    // The thing about these images: once we have an entry, we should be able to
    // assume that we already have the image URLs, because an entry cannot exist
    // without its parent feed, which knows the image URLs. Orphans are
    // impossible, thus a programming error.
    
    // Force UIKit to surpress default UIButton animation, which would interfere
    // with our view transition.
    
    UIView.performWithoutAnimation {
      feedButton.setTitle(entry.feedTitle, for: .normal)
      feedButton.layoutIfNeeded()
    }
    
    updatedLabel.text = StringRepository.string(from: entry.updated)
    
    if let duration = entry.duration,
      let text = StringRepository.string(from: duration) {
      durationLabel.text = text
    } else {
      durationLabel.isHidden = true
    }

    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
      let attributedText = StringRepository.string(for: entry)
      DispatchQueue.main.async {
        self?.content?.attributedText = attributedText

        if let offset = self?.restoredContentOffset,
          self?.restoredFrameSize == self?.scrollView.frame.size {
          self?.scrollView?.contentOffset = offset
          self?.restoredContentOffset = nil
        }

        self?.content?.isHidden = false

        UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) {
          self?.content?.alpha = 1
        }.startAnimation()
      }
    }
  }
  
  private func resetView() {
    feedButton.setTitle(nil, for: .normal)
    updatedLabel.text  = nil
    durationLabel.text = nil
    content.isHidden = true
    content.alpha = 0
  }
  
  override func viewWillLayoutSubviews() {
    let insets = navigationDelegate?.miniPlayerEdgeInsets ?? UIEdgeInsets.zero
    scrollView.contentInset = insets
    scrollView.scrollIndicatorInsets = insets
    
    if entryChanged {
      entry != nil ? configureView() : resetView()
      entryChanged = false
    }
   
    super.viewWillLayoutSubviews()
  }

  /// Remembers if the hero image has been set or loaded.
  private var imageLoaded = false

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    guard !imageLoaded, let entry = self.entry else {
      return
    }

    // For loading images in dynamic sizes, we need the layout first.

    avatar.image = nil
    Podest.images.loadImage(for: entry, into: avatar)

    imageLoaded = true
  }

  // MARK: State Preservation and Restoration

  private var restoredContentOffset: CGPoint?
  private var restoredFrameSize: CGSize?

  override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    locator?.encode(with: coder)

    coder.encode(scrollView.contentOffset, forKey: "contentOffset")
    coder.encode(scrollView.frame.size, forKey: "frameSize")
  }

  override func decodeRestorableState(with coder: NSCoder) {
    locator = EntryLocator(coder: coder)

    restoredContentOffset = coder.decodeCGPoint(forKey: "contentOffset")
    restoredFrameSize = coder.decodeCGSize(forKey: "frameSize")

    super.decodeRestorableState(with: coder)
  }
}


// MARK: - UIResponder

extension EpisodeViewController {
  
  @discardableResult override func resignFirstResponder() -> Bool {
    content?.resignFirstResponder()
    return super.resignFirstResponder()
  }
  
}

// MARK: - Action Sheets

extension EpisodeViewController: ActionSheetPresenting {}

// MARK: - Removing Action Sheet

extension EpisodeViewController {
 
  private static func makeDequeueAction(
    entry: Entry, viewController: EpisodeViewController) -> UIAlertAction {
    let t = NSLocalizedString("Remove Episode", comment: "Dequeue episode")
    
    return UIAlertAction(title: t, style: .destructive) {
      [weak viewController] action in
      Podest.userQueue.dequeue(entry: entry) { dequeued, error in
        if let er = error {
          os_log("dequeue error: %{public}@",
                 log: log, type: .error, er as CVarArg)
        }

        if dequeued.isEmpty {
          os_log("** not dequeued", log: log)
        }

        DispatchQueue.main.async {
          viewController?.isEnqueued = !dequeued.contains(entry)
        }
      }
    }
  }
  
  private static func makeRemoveActions(
    entry: Entry, viewController: EpisodeViewController) -> [UIAlertAction] {
    var actions =  [UIAlertAction]()
    
    let dequeue = makeDequeueAction(entry: entry, viewController: viewController)
    let cancel = makeCancelAction()
    
    actions.append(dequeue)
    actions.append(cancel)
    
    return actions
  }
  
  private func makeRemoveController() -> UIAlertController {
    guard let entry = self.entry else {
      fatalError("entry expected")
    }
    
    let alert = UIAlertController(
      title: entry.title, message: nil, preferredStyle: .actionSheet
    )
    
    let actions = EpisodeViewController.makeRemoveActions(
      entry: entry, viewController: self)
    
    for action in actions {
      alert.addAction(action)
    }
    
    return alert
  }
  
}

// MARK: - Sharing Action Sheet

extension EpisodeViewController {
  
  private static func makeMoreActions(entry: Entry) -> [UIAlertAction] {
    var actions = [UIAlertAction]()
    
    if let openLink = makeOpenLinkAction(string: entry.link) {
      actions.append(openLink)
    }

    let copyFeedURL = makeCopyFeedURLAction(string: entry.feed)
    actions.append(copyFeedURL)
    
    let cancel = makeCancelAction()
    actions.append(cancel)
    
    return actions
  }
  
  private func makeMoreController() -> UIAlertController {
    guard let entry = self.entry else {
      fatalError("entry expected")
    }
    
    let alert = UIAlertController(
      title: nil, message: nil, preferredStyle: .actionSheet
    )
    
    let actions = EpisodeViewController.makeMoreActions(entry: entry)
    
    for action in actions {
      alert.addAction(action)
    }
    
    return alert
  }
  
}

// MARK: - Configure Navigation Item

extension EpisodeViewController {

  @objc func onPlay(_ sender: Any) {
    navigationDelegate?.play(entry!)
  }

  private func makePlayButton(for entry: Entry) -> UIBarButtonItem {
    // Deliberately not changing the play button, just ignoring another tap for
    // now. Switching between .play and .pause felt too distracting. Accent the
    // player.
    return UIBarButtonItem(
      barButtonSystemItem: .play, target: self, action: #selector(onPlay))
  }

  @objc func onRemove(_ sender: UIBarButtonItem) {
    let alert = makeRemoveController()
    if let presenter = alert.popoverPresentationController {
      presenter.barButtonItem = sender
    }

    self.present(alert, animated: true, completion: nil)
  }

  @objc func onAdd(_ sender: UIBarButtonItem) {
    guard  let entry = self.entry else {
      fatalError("entry expected")
    }

    sender.isEnabled = false
    
    Podest.userQueue.enqueue(entries: [entry], belonging: .user) {
      [weak self] enqueued, error in
      if let er = error {
        os_log("enqueue error: %{public}@", type: .error, er as CVarArg)
      }

      if enqueued.isEmpty {
        os_log("** not enqueued", log: log)
      }

      DispatchQueue.main.async {
        sender.isEnabled = true
        self?.isEnqueued = enqueued.contains(entry)
      }
    }
  }

  private func makeQueueButton(for entry: Entry) -> UIBarButtonItem {
    if isEnqueued {
      return UIBarButtonItem(
        barButtonSystemItem: .trash, target: self, action: #selector(onRemove))
    } else {
      return UIBarButtonItem(
        barButtonSystemItem: .add, target: self, action: #selector(onAdd))
    }
  }

  @objc func onMore(_ sender: UIBarButtonItem) {
    let alert = makeMoreController()
    if let presenter = alert.popoverPresentationController {
      presenter.barButtonItem = sender
    }
    self.present(alert, animated: true, completion: nil)
  }

  private func makeMoreButton() -> UIBarButtonItem {
    return UIBarButtonItem(
      barButtonSystemItem: .action, target: self, action: #selector(onMore)
    )
  }

  private func configureNavigationItem() {
    guard let entry = self.entry else {
      return navigationItem.rightBarButtonItems = nil
    }

    let items = [
      makePlayButton(for: entry),
      makeMoreButton(),
      makeQueueButton(for: entry)
    ]

    navigationItem.rightBarButtonItems = items
  }

}

// MARK: - UITextViewDelegate

extension EpisodeViewController: UITextViewDelegate {
  
  func textView(
    _ textView: UITextView,
    shouldInteractWith URL: URL,
    in characterRange: NSRange
  ) -> Bool {
    guard URL.scheme == Podest.scheme else {
      return true
    }
    return !(navigationDelegate?.open(url: URL))!
  }
  
}
