//
//  SectionedDataSource.swift
//  Podest
//
//  Created by Michael Nisi on 21.12.17.
//  Copyright © 2017 Michael Nisi. All rights reserved.
//

import Foundation
import UIKit

struct Cell {
  let id: String
  let nib: UINib
}

struct Cells {

  static let suggestion = Cell(
    id: "SuggestionCellID",
    nib: UINib(nibName: "SuggestionCell", bundle: .main)
  )

  static let message = Cell(
    id: "MessageTableViewCellID",
    nib: UINib(nibName: "MessageTableViewCell", bundle: .main)
  )

  static let subtitle = Cell(
    id: "SubtitleTableViewCellID",
    nib: UINib(nibName: "SubtitleTableViewCell", bundle: .main)
  )

}

/// A section of a table view data model.
struct Section<Item: Equatable>: Equatable{
  let id: Int
  let title: String?
  var items: [Item]
  
  init(id: Int, title: String? = nil, items: [Item] = [Item]()) {
    self.id = id
    self.title = title
    self.items = items
  }
  
  /// The number of items in this section.
  var count: Int { return items.count }
  
  /// Append item to end of section.
  mutating func append(item: Item) {
    items.append(item)
  }

  var isEmpty: Bool {
    return items.isEmpty
  }

  var first: Item? {
    return items.first
  }
  
  static func ==(lhs: Section, rhs: Section) -> Bool {
    return lhs.id == rhs.id
  }
}

protocol SectionedDataSource: class {
  associatedtype Item: Equatable
  var sections: [Section<Item>] { get set }
}

extension SectionedDataSource {

  /// Returns updates after merging `sections` into `itemsByIndexPath`.
  static func makeUpdates(old: [Section<Item>], new: [Section<Item>]) -> Updates {
    let updates = Updates()
    let numberOfSections = old.count
    
    for (n, section) in new.enumerated() {
      var rows = 0
      var items: [Item]?
      if numberOfSections <= n {
        updates.insertSection(at: n)
      } else {
        let prev = old[n]
        rows = prev.count
        items = prev.items
        if section != prev || new.count != old.count {
          updates.reloadSection(at: n)
        }
      }
      for (i, item) in (section.items).enumerated() {
        let indexPath = IndexPath(row: i, section: n)
        if rows <= i {
          updates.insertRow(at: indexPath)
        } else {
          if let prev = items?[i] {
            if item != prev {
              updates.reloadRow(at: indexPath)
            }
          }
        }
      }
      var x = rows
      while x > section.items.count {
        x -= 1
        let indexPath = IndexPath(row: x, section: n)
        updates.deleteRow(at: indexPath)
      }
    }
    var y = numberOfSections
    while y > new.count {
      y -= 1
      updates.deleteSection(at: y)
    }
    
    return updates
  }
  
}

extension SectionedDataSource {
  
  func itemAt(indexPath: IndexPath) -> Item? {
    guard sections.indices.contains(indexPath.section) else {
      return nil
    }

    let section = sections[indexPath.section]

    guard section.items.indices.contains(indexPath.row) else {
      return nil
    }

    return section.items[indexPath.row]
  }
  
  var isEmpty: Bool {
    return sections.isEmpty
  }
  
}
