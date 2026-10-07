import Foundation
import AcceSSHCore
import UIKit

/// Clipboard access. Copies of terminal output stay on this device (no Universal Clipboard)
/// and expire after ten minutes, because output can contain secrets.
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
    }

    static var text: String? {
        UIPasteboard.general.string
    }
}
