//
//  FileRepository.swift
//  Podest
//
//  Created by Michael Nisi on 28.02.18.
//  Copyright © 2018 Michael Nisi. All rights reserved.
//

import Foundation
import os.log
import FeedKit
import Ola

private let log = OSLog(subsystem: "ink.codes.podest", category: "files")

final class FileRepository: NSObject {
  
  private let userQueue: Queueing
  
  init(userQueue: Queueing) {
    self.userQueue = userQueue
  }
  
  // MARK: Synchronized Access
  
  /// An internal serial queue for synchronized access.
  private let sQueue = DispatchQueue(
    label: "ink.codes.podest.FileRepository-\(UUID().uuidString).serial")
  
  private var _fileProxy: FileProxying?
  private var fileProxy: FileProxying {
    get {
      return sQueue.sync {
        guard _fileProxy != nil else {
          _fileProxy = FileProxy(
            identifier: "ink.codes.playback",
            maxBytes: .max,
            delegate: self
          )
          return _fileProxy!
        }
        return _fileProxy!
      }
    }
    set {
      sQueue.sync {
        _fileProxy = newValue
      }
    }
  }

  // MARK: Reachability

  /// If this reachability probe is set, it gets activated, listening for
  /// connectivity changes. Resetting to `nil` invalidates the previous probe,
  /// uninstalling the reachability callback.
  ///
  /// While running in the background, the latest reachability callback gets
  /// deferred. If we don’t get a chance to invalidate our probe, it runs when
  /// the app is returning to the foreground. That’s not what we want, `flush`
  /// when our app is leaving the foreground.
  ///
  /// If installing the reachability callback fails, we give up and abandon
  /// the probe.
  private var probe: Ola? {
    didSet {
      oldValue?.invalidate()
      
      guard let p = probe else {
        return
      }

      let ok = p.activate { [weak self] status in
        os_log("entering reachability callback block with status: %{public}@",
               log: log, type: .debug, String(describing: status))
        guard case .reachable = status else {
          return
        }
        
        self?.preloadQueue()
      }
      
      if !ok {
        os_log("could not initialize reachability probe", log: log)
        flush()
      }
    }
  }

  /// Counts the number of files removed at once, limited to 16.
  private var fileRemovingCount = 16

}

// MARK: - Respecting User Settings

extension FileRepository {
  
  enum MobileData: Error {
    case unknown
    case off
    case noStreaming
    case noDownloading
  }

  private static func makeMobileData(status: OlaStatus) -> MobileData? {
    switch status {
    case .cellular:
      let defaults = UserDefaults.standard
      switch (defaults.mobileDataStreaming, defaults.mobileDataDownloads) {
      case (true, true):
        return nil
      case (true, false):
        return .noDownloading
      case (false, true):
        return .noStreaming
      case (false, false):
        return .off
      }
    case .reachable:
      return nil
    case .unknown:
      return .unknown
    }
  }
  
  /// Returns an error if user preferences prohibit downloading or streaming of
  /// the file at `url`. For this is performing IO, executing this on the main
  /// queue traps
  ///
  /// - Parameter url: The URL you want to stream or download.
  ///
  /// - Returns: Returns informative error or `nil`.
  private func reach(url: URL) -> MobileData? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    
    guard let host = url.host, let p = Ola(host: host) else {
      return .unknown
    }
    
    let status = p.reach()
    
    switch status {
    case .cellular, .unknown:
      self.probe = p
    case .reachable:
      self.probe = nil
    }
    
    return FileRepository.makeMobileData(status: status)
  }

  /// Returns true if downloading the file at `url` would be OK.
  private func shouldDownload(url: URL) -> Bool {
    if let er = reach(url: url) {
      switch er {
      case .noDownloading, .off, .unknown:
        return false
      case .noStreaming:
        return true
      }
    }
    
    return true
  }

}

// MARK: - Downloading

extension FileRepository: Downloading {
  
  func handleEventsForBackgroundURLSession(
    identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    fileProxy.handleEventsForBackgroundURLSession(
      identifier: identifier,
      completionHandler: completionHandler
    )
  }

  private func url(matching url: URL, streaming: Bool) throws -> URL {
    dispatchPrecondition(condition: .notOnQueue(.main))
    
    if let local = try fileProxy.localURL(matching: url) {
      return local
    }
    
    if streaming, let error = reach(url: url) {
      switch error {
      case .off, .noStreaming, .unknown:
        throw error
      case .noDownloading:
        break
      }
    }
    
    guard
      UserDefaults.standard.automaticDownloads, shouldDownload(url: url) else {
      os_log("settings prevented file preloading",
             log: log, type: .info)
      return url
    }
    
    return try fileProxy.url(matching: url)
  }
  
  func url(for url: URL) throws -> URL {
    return try self.url(matching: url, streaming: true)
  }
  
  func preload(url: URL) {
    DispatchQueue.global().async {
      os_log("preloading: %{public}@",
             log: log, type: .debug, url as CVarArg)

      do {
        let _ = try self.url(matching: url, streaming: false)
      } catch {
        os_log("caught preloading error: %{public}@",
               log: log, type: .error, error as CVarArg)
      }
    }
  }

  func cancel(url: URL) {
    DispatchQueue.global(qos: .background).async {
      os_log("cancelling download: %{public}@",
             log: log, type: .debug, url as CVarArg)

      self.fileProxy.cancelDownloads(matching: url)
    }
  }
  
  func remove(url: URL) {
    DispatchQueue.global(qos: .background).async {
      if let removed = self.fileProxy.removeFile(matching: url) {
        os_log("removed file: %{public}@",
               log: log, type: .info , removed as CVarArg)
      }

      os_log("cancelling downloads: %{public}@",
             log: log, type: .debug, url as CVarArg)
      
      self.fileProxy.cancelDownloads(matching: url)
    }
  }

  func flush() {
    guard probe != nil else {
      return
    }

    os_log("releasing probe", log: log, type: .debug)
    
    probe = nil
  }

  func preloadQueue(
    removingFiles: Bool = false,
    completionHandler: ((Error?) -> Void)? = nil
  ) {
    dispatchPrecondition(condition: .notOnQueue(.main))
    
    os_log("preloading queue", log: log, type: .debug)

    if probe != nil {
      flush()
    }

    let anywhere = URL(string: "https://apple.com")!
    let downloading = shouldDownload(url: anywhere)
    
    guard UserDefaults.standard.automaticDownloads, downloading else {
      os_log("settings or reachability prevented queue preloading",
             log: log, type: .info)
      completionHandler?(nil)
      return
    }
    
    var entriesBlockError: Error?
    var acc = [Entry]()
    
    userQueue.populate(entriesBlock: { entries, error in
      if error != nil {
        if let er = error as? FeedKitError {
          switch er {
          case .missingEntries(let locators):
            os_log("missing entries: %{public}@",
                   log: log, locators)
          default:
            entriesBlockError = error
          }
        } else {
          entriesBlockError = error
        }
      }
      
      acc = acc + entries
    }) { completionError in
      var proxyError: Error?
      
      let urls: [URL] = acc.compactMap {
        guard let string = $0.enclosure?.url else {
          os_log("skipping entry due to missing enclosure: %{public}@",
                 log: log, $0.title)
          return nil
        }
        return URL(string: string)
      }
      
      // This is a heavy loop, limiting concurrent downloads to the first 64,
      // for no particular reason really, relying on URLSession for doing the
      // right thing. It’s just that after a fat sync, the queue can get really
      // long, it’s not limited, so some arbitrary limit makes sense here, I
      // guess. Initializing background ad infinitum doesn’t sound like a good
      // idea, does it?
      
      let max = 64
      var count = 0
      
      for url in urls {
        guard count < max else {
          os_log("aborting queue preloading: too many files", log: log)
          break
        }
        
        do {
          if !(try self.fileProxy.url(matching: url)).isFileURL {
            count = count + 1
          }
        } catch {
          proxyError = error
          continue
        }
      }
      
      // Picking the first error.
      let er = entriesBlockError ?? completionError ?? proxyError
      
      if let accErr = er {
        os_log("error while preloading queue: %{public}@",
               log: log, type: .error, accErr as CVarArg)
      }

      // We are only removing files while downloading is possible.
      guard downloading, removingFiles else {
        completionHandler?(er)
        return
      }
      
      do {
        os_log("removing files except: %{public}@",
               log: log, type: .debug, urls)
        
        try self.fileProxy.removeAll(keeping: urls)
      } catch {
        os_log("removing files caught: %{public}@",
               log: log, error as CVarArg)
      }
      
      os_log("removing files complete", log: log, type: .info)
      self.fileRemovingCount = 16
      completionHandler?(er)
    }
  }
  
}

// MARK: - FileProxyDelegate

extension FileRepository: FileProxyDelegate {
  
  var allowsCellularAccess: Bool {
    return UserDefaults.standard.mobileDataDownloads
  }
  
  /// Deletes the file if it’s older than three days and if the maximum file
  /// removing count has not been exceeded yet. We are limiting this for not
  /// hanging on IO for too long.
  func validate(_ proxy: FileProxying, removing url: URL, modified: Date) -> Bool {
    let stale = modified.timeIntervalSinceNow < 3600 * 24 * -3

    guard fileRemovingCount > 0, stale else {
      os_log("not removing: ( %i, %i )", log: log, type: .debug,
             fileRemovingCount, stale)

      return false
    }

    fileRemovingCount = fileRemovingCount - 1
    os_log("removing: %@", log: log, type: .debug, url as CVarArg)
    return true
  }
  
}

