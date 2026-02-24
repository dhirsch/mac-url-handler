import AppKit
import Foundation

let shimBundleID = "com.danielhirsch.urlhandlershim"

struct HostRule: Codable {
    let host: String
    let bundleID: String
}

struct ShimConfig: Codable {
    var defaultHTTPSBundleID: String
    var rules: [HostRule]
}

final class URLHandlerDelegate: NSObject, NSApplicationDelegate {
    private var handledAnyURL = false
    private var didInstallEventHandler = false

    override init() {
        super.init()
        installEventHandlerIfNeeded()
    }

    private func configURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("URLHandlerShim", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func loadConfig() -> ShimConfig? {
        let url = configURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShimConfig.self, from: data)
    }

    private func hostMatches(ruleHost: String, actualHost: String) -> Bool {
        let rule = ruleHost.lowercased()
        let host = actualHost.lowercased()
        if rule.hasPrefix("*.") {
            let suffix = String(rule.dropFirst(1))
            return host.hasSuffix(suffix)
        }
        return host == rule
    }

    private func targetBundleID(for url: URL, config: ShimConfig) -> String {
        let host = (url.host ?? "").lowercased()
        for rule in config.rules {
            if hostMatches(ruleHost: rule.host, actualHost: host) {
                return rule.bundleID
            }
        }
        return config.defaultHTTPSBundleID
    }

    private func openViaChromePWAIfApplicable(bundleID: String, url: URL) -> Bool {
        let prefix = "com.google.Chrome.app."
        guard bundleID.hasPrefix(prefix) else { return false }
        let appID = String(bundleID.dropFirst(prefix.count))
        guard !appID.isEmpty else { return false }

        guard let chromeAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            return false
        }
        let executablePath = chromeAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Google Chrome", isDirectory: false)
            .path
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--app-id=\(appID)", url.absoluteString]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private func openWithBundleID(_ bundleID: String, url: URL, completion: @escaping (Bool) -> Void) {
        if bundleID == shimBundleID {
            completion(false)
            return
        }

        if openViaChromePWAIfApplicable(bundleID: bundleID, url: url) {
            completion(true)
            return
        }

        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            completion(false)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID, url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            completion(process.terminationStatus == 0)
        } catch {
            completion(false)
        }
    }

    private func open(_ url: URL) {
        handledAnyURL = true
        guard let config = loadConfig() else {
            _ = NSWorkspace.shared.open(url)
            scheduleExit()
            return
        }

        let targetBundleID = targetBundleID(for: url, config: config)
        openWithBundleID(targetBundleID, url: url) { success in
            if success {
                self.scheduleExit()
                return
            }
            self.openWithBundleID(config.defaultHTTPSBundleID, url: url) { _ in
                self.scheduleExit()
            }
        }
    }

    private func scheduleExit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard !didInstallEventHandler else { return }
        didInstallEventHandler = true
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw) else {
            scheduleExit()
            return
        }
        open(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEventHandlerIfNeeded()

        let cliURLs = CommandLine.arguments.dropFirst().compactMap { URL(string: $0) }
        if let first = cliURLs.first {
            open(first)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !self.handledAnyURL {
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = URLHandlerDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
