// deadbolt-bridge — Chrome's native-messaging host for Deadbolt.
//
// Chrome starts this (only for the Deadbolt extension, per the host manifest's allowed_origins) and talks to it
// over stdin/stdout: each message is a 4-byte little-endian length + UTF-8 JSON. The bridge holds no secrets and
// makes no decisions: it forwards each message to the Deadbolt app over a Unix socket in the shared app-group
// container (BridgeClient) and returns the answer. The app checks this binary's code signature before answering.

import AppKit
import Foundation

func readMessage() -> Data? {
    var len: UInt32 = 0
    guard fread(&len, 4, 1, stdin) == 1 else { return nil }
    let n = Int(UInt32(littleEndian: len))
    guard n > 0, n < 4 << 20 else { return nil }
    var buf = [UInt8](repeating: 0, count: n)
    guard fread(&buf, 1, n, stdin) == n else { return nil }
    return Data(buf)
}

func writeMessage(_ data: Data) {
    var len = UInt32(data.count).littleEndian
    fwrite(&len, 4, 1, stdout)
    data.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, data.count, stdout) }
    fflush(stdout)
}

func reply(_ obj: [String: Any]) { writeMessage((try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)) }

/// Starts Deadbolt if it isn't running, so the extension works after a restart.
func launchApp() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.osborne.deadbolt") {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }
}

while let message = readMessage() {
    if let answer = BridgeClient.forward(message) {
        writeMessage(answer)
        continue
    }
    launchApp()
    var answered = false
    for _ in 0..<20 {                      // give the app up to ~4 s to open its socket
        usleep(200_000)
        if let answer = BridgeClient.forward(message) { writeMessage(answer); answered = true; break }
    }
    if !answered { reply(["ok": false, "error": "notRunning"]) } // tell the extension plainly
    if ferror(stdout) != 0 { break }
}
