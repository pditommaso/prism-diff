// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
//
// Posts one key press (key down + key up) to a single process, by PID,
// with CGEvent.postToPid. Unlike System Events `keystroke`, the event is
// delivered to that process only, never to whichever app is frontmost, so
// a focus change can never send the keys to another application.
//
// Usage: keypost <pid> <virtual key code> [modifier...]
//   modifiers: cmd, shift, opt, ctrl
//   e.g. `keypost 1234 13 cmd` sends Cmd-W (key code 13 is "w" on ANSI).
//
// Exit status: 0 when the events were posted, 1 when they could not be
// created, 2 on a usage error. Posting needs the Accessibility permission.
//
// Compiled on demand by scripts/accept/lib.sh into build/tools/keypost.

import CoreGraphics
import Foundation

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("keypost: \(message)\nusage: keypost <pid> <key code> [cmd|shift|opt|ctrl...]\n".utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage("missing arguments") }
guard let pid = Int32(arguments[0]), pid > 0 else { usage("invalid pid '\(arguments[0])'") }
guard let keyCode = UInt16(arguments[1]), keyCode < 128 else { usage("invalid key code '\(arguments[1])'") }

var flags: CGEventFlags = []
for name in arguments.dropFirst(2) {
    switch name {
    case "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "opt": flags.insert(.maskAlternate)
    case "ctrl": flags.insert(.maskControl)
    default: usage("unknown modifier '\(name)'")
    }
}

let source = CGEventSource(stateID: .privateState)
guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
else {
    FileHandle.standardError.write(Data("keypost: cannot create key events\n".utf8))
    exit(1)
}
down.flags = flags
up.flags = flags
down.postToPid(pid)
usleep(20_000)
up.postToPid(pid)
