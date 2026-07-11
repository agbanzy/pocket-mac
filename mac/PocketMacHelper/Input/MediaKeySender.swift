import Foundation
import AppKit
import PocketMacKit

/// Sends system-defined media / hardware keys (play, volume, brightness…) as `NSEvent` subtype 8
/// (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`): a key-down (`0xA`) followed by a key-up (`0xB`).
enum MediaKeySender {
    // NX_KEYTYPE_* constants from IOKit's `ev_keymap.h`.
    private static func keyCode(for key: MediaKey) -> Int32 {
        switch key {
        case .volumeUp: 0        // NX_KEYTYPE_SOUND_UP
        case .volumeDown: 1      // NX_KEYTYPE_SOUND_DOWN
        case .brightnessUp: 2    // NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: 3  // NX_KEYTYPE_BRIGHTNESS_DOWN
        case .mute: 7            // NX_KEYTYPE_MUTE
        case .playPause: 16      // NX_KEYTYPE_PLAY
        case .next: 17           // NX_KEYTYPE_NEXT
        case .previous: 18       // NX_KEYTYPE_PREVIOUS
        }
    }

    static func send(_ key: MediaKey) {
        let code = keyCode(for: key)
        post(code: code, down: true)
        post(code: code, down: false)
    }

    private static func post(code: Int32, down: Bool) {
        let flagsRaw: UInt = down ? 0xA00 : 0xB00
        let state: Int32 = down ? 0xA : 0xB
        let data1 = Int((code << 16) | (state << 8))
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flagsRaw),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
