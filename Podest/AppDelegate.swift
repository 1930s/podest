//
//  AppDelegate.swift
//  Podest
//
//  Created by Michael on 11/11/14.
//  Copyright (c) 2014 Michael Nisi. All rights reserved.
//

import CloudKit
import FeedKit
import UIKit
import os.log

private let log = OSLog(subsystem: "ink.codes.podest", category: "app")

/// Receiving application events, AppDelegate is responsible for global things,
/// namely triggering of background fetching, iCloud synchronization, and file
/// downloading, providing a clear view over these central route entry points,
/// close to their respective event sources.
///
/// Do not sync from anywhere else.
@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  private var shouldRestoreState = true
  private var shouldSaveState = true

  /// The **root** view controller of this app.
  private var root: RootViewController {
    dispatchPrecondition(condition: .onQueue(.main))
    return window?.rootViewController as! RootViewController
  }

  /// Application level observers must only run while application is active.
  private var observers = [NSObjectProtocol]()

  /// `true` while pulling iCloud.
  private var isPulling = false

  /// `true` while pushing to iCloud.
  private var isPushing = false
}

// MARK: - Interpreting Background Fetch Results

extension AppDelegate {

  /// Produces a background fetch result and logs its interpretation. While
  /// `newData` is `true` `.newData` is returned, overriding the error.
  ///
  /// - Parameters:
  ///   - newData: `true` if new data has been received.
  ///   - error: The error to take into consideration.
  private static func makeBackgroundFetchResult(
    _ newData: Bool, _ error: Error?) -> UIBackgroundFetchResult {
    guard error == nil else {
      if newData {
        os_log("fetch completed with new data and error: %{public}@",
               log: log, type: .error, error! as CVarArg)
        return .newData
      } else {
        os_log("fetch failed: %{public}@",
               log: log, type: .error, error! as CVarArg)
        return .failed
      }
    }
    if newData {
      os_log("fetch completed with new data",
             log: log, type: .info)
      return .newData
    } else {
      os_log("fetch completed with no data",
             log: log, type: .info)
      return .noData
    }
  }

}

// MARK: - Syncing with iCloud

extension AppDelegate {

  /// Pulls iCloud, integrates new data, and reloads the queue locally to update
  /// views for snapshotting.
  ///
  /// Pulling has presedence over pushing.
  ///
  /// - Parameters:
  ///   - completionBlock: The completion block executing on the main queue.
  /// when done.
  private func pull(completionBlock: ((UIBackgroundFetchResult) -> Void)? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))

    if isPushing {
      os_log("** pulling iCloud while pushing", log: log)
    } else {
      os_log("pulling iCloud", log: log, type: .info)
    }

    isPulling = true

    Podest.iCloud.pull { newData, error in
      let result = AppDelegate.makeBackgroundFetchResult(newData, error)

      if case .newData = result {
        os_log("reloading queue after merge", log: log, type: .info)

        DispatchQueue.main.async {
          self.root.reload { error in
            if let er = error {
              os_log("reloading queue failed: %{public}@",
                     log: log, type: .error, er as CVarArg)
            }
            DispatchQueue.main.async {
              self.isPulling = false
              completionBlock?(result)
            }
          }
        }
      } else {
        DispatchQueue.main.async {
          self.isPulling = false
          completionBlock?(result)
        }
      }
    }
  }

  /// Pushes user data to iCloud. **Must run on the main queue.**
  private func push(completionBlock: (() -> Void)? = nil) {
    guard !isPulling, !isPushing else {
      os_log("already syncing", log: log)
      completionBlock?()
      return
    }

    os_log("pushing to iCloud", log: log, type: .info)

    isPushing = true

    Podest.iCloud.push { [weak self] error in
      if let er = error {
        os_log("push failed: %{public}@",
               log: log, type: .error, er as CVarArg)
      }

      DispatchQueue.main.async {
        self?.isPushing = false
      }

      completionBlock?()
    }
  }

}

// MARK: - Initializing the App

extension AppDelegate {

  func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]?
  ) -> Bool {
    os_log("beginning launch process with options: %{public}@",
           log: log, type: .info, String(describing: launchOptions))

    shouldRestoreState = launchOptions?[.url] == nil

    window?.tintColor = UIColor(named: "Purple")

    application.setMinimumBackgroundFetchInterval(3600)

    if !Podest.settings.noSync {
      application.registerForRemoteNotifications()
    }

    return true
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]?
  ) -> Bool {
    os_log("finished launch process with options: %{public}@",
           log: log, type: .info, String(describing: launchOptions))

    let defaults: [String : Any] = [
      UserDefaults.mobileDataDownloadsKey: false,
      UserDefaults.mobileDataStreamingKey: false,
      UserDefaults.automaticDownloadsKey: !Podest.settings.noDownloading,
      UserDefaults.lastUpdateTimeKey: 0
    ]

    os_log("registering defaults: %{public}@",
           log: log, type: .info, defaults)

    UserDefaults.standard.register(defaults: defaults)

    os_log("checking application state", log: log, type: .debug)

    switch application.applicationState {
    case .active, .inactive:
      os_log("moving to foreground", log: log, type: .debug)
      return true
    case .background:
      os_log("moving to background", log: log, type: .debug)
      return true
    }
  }

}

// MARK: - Managing App State Restoration

extension AppDelegate {

  func application(
    _ application: UIApplication,
    shouldRestoreApplicationState coder: NSCoder) -> Bool {
    return shouldRestoreState
  }

  func application(
    _ application: UIApplication,
    shouldSaveApplicationState coder: NSCoder) -> Bool {
    return shouldSaveState
  }

}

// MARK: - Opening a URL-Specified Resource

extension AppDelegate {

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    return root.open(url: url)
  }

}

// MARK: - Downloading Data in the Background

extension AppDelegate {

  func application(
    _ application: UIApplication,
    performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    os_log("beginning background fetch", log: log, type: .info)

    dispatchPrecondition(condition: .onQueue(.main))

    root.update { newData, error in
      let result = AppDelegate.makeBackgroundFetchResult(newData, error)

      func done() {
        DispatchQueue.main.async {
          if application.applicationState != .active {
            self.flush()
            self.closeFiles()
          }
          completionHandler(result)
        }
      }

      guard case .newData = result else {
        return done()
      }

      // In non-active states pushing manually is required, because we are not
      // observing queue or library changes. This enables us to execute the
      // completion block, after pushing to iCloud has been completed. In
      // background fetching, nothing can run after the completion handler.

      switch application.applicationState {
      case .active:
        return done()
      case .background, .inactive:
        self.push() {
          done()
        }
      }
    }
  }

  /// Passes the `completionHandler` to the file repo, including `identifier`,
  /// but there˚s just one background session at this time.
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void) {
    os_log("handling events for background URL session: %@",
           log: log, type: .info, identifier)
    Podest.files.handleEventsForBackgroundURLSession(identifier: identifier) {
      DispatchQueue.main.async {
        completionHandler()
      }
    }
  }

  /// Pulls changes from iCloud.
  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable : Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult
    ) -> Void) {
    os_log("received notification: %{public}@",
           log: log, type: .info, String(describing: userInfo))

    let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)

    guard let subscriptionID = notification.subscriptionID else {
      os_log("unhandled remote notification", log: log, type: .error)
      return
    }

    // We receive a notification per zone. How can we optimize this?

    switch subscriptionID {
    case UserDB.subscriptionID:
      pull(completionBlock: completionHandler)

    default:
      os_log("failing fetch completion: unidentified subscription: %{public}@",
             log: log, type: .error, subscriptionID)
      completionHandler(.failed)
    }
  }

}

// MARK: - Handling Remote Notification Registration

extension AppDelegate {

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    os_log("registered for remote notifications with device token: %@",
           log: log, type: .info, deviceToken as CVarArg)

    let nc = NotificationCenter.default

    nc.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
      Podest.iCloud.resetAccountStatus()
      self.pull()
    }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    os_log("failed to register: %{public}@",
           log: log, type: .error, error as CVarArg)
  }

}

// MARK: - Responding to App State Changes and System Events

extension AppDelegate {

  /// Installs this object into the object tree, observing changes, etc.
  private func install(_ application: UIApplication) {
    precondition(observers.isEmpty)

    os_log("installing", log: log, type: .info)

    observers.append(NotificationCenter.default.addObserver(
      forName: .FKRemoteRequest,
      object: nil,
      queue: .main
    ) { _ in
      precondition(application.applicationState == .active)
      Podest.networkActivity.increase()
    })

    observers.append(NotificationCenter.default.addObserver(
      forName: .FKRemoteResponse,
      object: nil,
      queue: .main
    ) { _ in
      precondition(application.applicationState == .active)
      Podest.networkActivity.decrease()
    })

    // Deferring setting delegates: applicationDidBecomeActive(_ application:)
  }

  /// Uninstalls this object from the object tree.
  private func uninstall() {
    os_log("uninstalling", log: log, type: .info)

    Podest.userQueue.queueDelegate = nil
    Podest.userLibrary.libraryDelegate = nil

    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }

    observers.removeAll()
  }

  private func closeFiles() {
    os_log("closing files", log: log, type: .info)

    Podest.userCaching.closeDatabase()
    Podest.feedCaching.closeDatabase()
  }

  private func flush() {
    os_log("flushing caches", log: log, type: .info)

    StringRepository.purge()
    Podest.images.flush()
    Podest.files.flush()

    do {
      try Podest.userCaching.flush()
      try Podest.feedCaching.flush()
    } catch {
      os_log("flushing failed: %{public}@",
             log: log, type: .error, error as CVarArg)
    }
  }

  func applicationWillResignActive(_ application: UIApplication) {
    os_log("will resign active", log: log, type: .info)

    uninstall()
    Podest.networkActivity.reset()
    flush()
    closeFiles()
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    os_log("did become active", log: log, type: .info)

    install(application)

    func updateQueue() -> Void {
      DispatchQueue.main.async {
        self.root.update { _, error in
          if let er = error {
            os_log("updating queue produced error: %{public}@",
                   log: log, er as CVarArg)
          }

          Podest.networkActivity.decrease()

          Podest.userQueue.queueDelegate = self
          Podest.userLibrary.libraryDelegate = self

          self.isPulling = false
        }
      }
    }

    // We are updating the queue before leaving this scope.

    guard !Podest.settings.noSync else {
      return updateQueue()
    }

    guard Podest.iCloud.isAccountStatusKnown else {
      os_log("accessing iCloud", log: log, type: .info)

      Podest.networkActivity.increase()
      isPulling = true

      return Podest.iCloud.pull { _, error in
        if let er = error {
          os_log("iCloud: %{public}@", log: log, String(describing: er))
        }
        updateQueue()
      }
    }

    updateQueue()
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    os_log("did enter background", log: log, type: .info)
    // If we have been launched into the background, we are idly waiting for
    // `application(application: performFetchWithCompletionHandler:)`.
  }

  func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    flush()
  }

  func applicationWillTerminate(_ application: UIApplication) {
    uninstall()
    flush()
    closeFiles()
  }

}

/// Handling Library Changes

extension AppDelegate: LibraryDelegate {

  func library(_ library: Subscribing, changed urls: Set<FeedURL>) {
    DispatchQueue.main.async { [weak self] in
      self?.root.updateIsSubscribed(using: urls)

      self?.push()
    }
  }

}

/// Handling Queue Changes

extension AppDelegate: QueueDelegate {

  func queue(_ queue: Queueing, changed guids: Set<EntryGUID>) {
    DispatchQueue.main.async { [weak self] in
      self?.root.updateIsEnqueued(using: guids)
      self?.root.reload()

      self?.push()
    }
  }

  func queue(_ queue: Queueing, enqueued: EntryGUID, enclosure: Enclosure?) {
    guard let str = enclosure?.url, let url = URL(string: str) else {
      return
    }

    Podest.files.preload(url: url)
  }

  func queue(_ queue: Queueing, dequeued: EntryGUID, enclosure: Enclosure?) {
    guard let str = enclosure?.url, let url = URL(string: str) else {
      return
    }

    Podest.files.cancel(url: url)
  }

}
