import SwiftUI

/// Coarse lifecycle of the link to the Mac, mapped to the connection chip's colors.
enum ConnectionState: Equatable, Sendable {
    case idle                 // no paired Mac / nothing happening
    case discovering          // browsing the LAN
    case connecting           // TCP + Noise handshake in flight
    case secured              // encrypted session live
    case offline(String)      // last attempt failed or the session dropped

    var label: String {
        switch self {
        case .idle: "Idle"
        case .discovering: "Discovering"
        case .connecting: "Connecting"
        case .secured: "Secured"
        case .offline: "Offline"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle.dashed"
        case .discovering: "dot.radiowaves.left.and.right"
        case .connecting: "arrow.triangle.2.circlepath"
        case .secured: "lock.fill"
        case .offline: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .discovering: .blue
        case .connecting: .orange
        case .secured: .green
        case .offline: .red
        }
    }

    var isBusy: Bool {
        switch self {
        case .discovering, .connecting: true
        default: false
        }
    }

    var isSecured: Bool {
        if case .secured = self { return true }
        return false
    }
}
