#!/usr/bin/env swift

import Foundation
import CoreServices
import AppKit

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case notFound(String)
    case setFailed(OSStatus)
    case io(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .notFound(let message):
            return message
        case .setFailed(let status):
            return "Failed to set handler (OSStatus \(status))."
        case .io(let message):
            return message
        }
    }
}

struct HostRule: Codable {
    let host: String
    let bundleID: String
}

struct ShimConfig: Codable {
    var defaultHTTPSBundleID: String
    var rules: [HostRule]
}

let shimBundleID = "com.danielhirsch.urlhandlershim"

func usage() -> String {
    return """
    URL Handler Tool (macOS)

    Usage:
      ./url-handler.swift doctor
      ./url-handler.swift list
      ./url-handler.swift get <scheme>
      ./url-handler.swift set <scheme> <bundle-id>
      ./url-handler.swift open <url>
      ./url-handler.swift host-rule init
      ./url-handler.swift host-rule list
      ./url-handler.swift host-rule add <host> <bundle-id>
      ./url-handler.swift host-rule remove <host>
      ./url-handler.swift host-rule default <bundle-id>
      ./url-handler.swift build-shim
      ./url-handler.swift install-shim

    Examples:
      ./url-handler.swift doctor
      ./url-handler.swift list
      ./url-handler.swift get mailto
      ./url-handler.swift set mailto com.apple.mail
      ./url-handler.swift open zoommtg://zoom.us/join
      ./url-handler.swift host-rule add meet.google.com us.zoom.xos
      ./url-handler.swift install-shim
    """
}

func appPath(for bundleID: String) -> String? {
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
}

func handlerBundleID(for scheme: String) -> String? {
    guard let probeURL = URL(string: "\(scheme)://example"),
          let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
        return nil
    }
    return Bundle(url: appURL)?.bundleIdentifier
}

func shimConfigURL() throws -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir = home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("URLHandlerShim", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        throw CLIError.io("Failed to create shim config directory: \(error)")
    }
    return dir.appendingPathComponent("config.json")
}

func currentHTTPSBundleID() throws -> String {
    guard let probeURL = URL(string: "https://example.com"),
          let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL),
          let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
        throw CLIError.notFound("Could not determine current https handler.")
    }
    return bundleID
}

func loadShimConfig() throws -> ShimConfig {
    let configURL = try shimConfigURL()
    if !FileManager.default.fileExists(atPath: configURL.path) {
        return ShimConfig(defaultHTTPSBundleID: try currentHTTPSBundleID(), rules: [])
    }
    do {
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(ShimConfig.self, from: data)
    } catch {
        throw CLIError.io("Failed to read shim config: \(error)")
    }
}

func saveShimConfig(_ config: ShimConfig) throws {
    let configURL = try shimConfigURL()
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        print("Saved config: \(configURL.path)")
    } catch {
        throw CLIError.io("Failed to write shim config: \(error)")
    }
}

func getHandler(for scheme: String) throws {
    guard let probeURL = URL(string: "\(scheme)://example") else {
        throw CLIError.usage("Invalid scheme: \(scheme)")
    }
    guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
        throw CLIError.notFound("No default handler found for scheme '\(scheme)'.")
    }

    let bundleID = Bundle(url: appURL)?.bundleIdentifier ?? "<unknown-bundle-id>"
    print("\(scheme) -> \(bundleID) (\(appURL.path))")
}

func listHandlers() throws {
    guard
        let defaults = UserDefaults(suiteName: "com.apple.LaunchServices/com.apple.launchservices.secure"),
        let rawHandlers = defaults.array(forKey: "LSHandlers") as? [[String: Any]]
    else {
        throw CLIError.notFound("Could not read LaunchServices handler database.")
    }

    var handlersByScheme: [String: String] = [:]

    for entry in rawHandlers {
        guard let scheme = (entry["LSHandlerURLScheme"] as? String)?.lowercased() else {
            continue
        }
        let bundleID =
            (entry["LSHandlerRoleAll"] as? String)
            ?? (entry["LSHandlerRoleViewer"] as? String)
            ?? (entry["LSHandlerRoleEditor"] as? String)
            ?? (entry["LSHandlerRoleShell"] as? String)

        guard let bundleID else { continue }
        handlersByScheme[scheme] = bundleID
    }

    if handlersByScheme.isEmpty {
        throw CLIError.notFound("No URL scheme handlers found in LaunchServices database.")
    }

    for scheme in handlersByScheme.keys.sorted() {
        guard let bundleID = handlersByScheme[scheme] else { continue }
        if let path = appPath(for: bundleID) {
            print("\(scheme) -> \(bundleID) (\(path))")
        } else {
            print("\(scheme) -> \(bundleID)")
        }
    }
}

func setHandler(for scheme: String, bundleID: String) throws {
    let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
    guard status == noErr else {
        throw CLIError.setFailed(status)
    }

    if let path = appPath(for: bundleID) {
        print("Set \(scheme) -> \(bundleID) (\(path))")
    } else {
        print("Set \(scheme) -> \(bundleID)")
    }
}

func hostRuleInit() throws {
    let config = ShimConfig(defaultHTTPSBundleID: try currentHTTPSBundleID(), rules: [])
    try saveShimConfig(config)
    print("Initialized shim config with default browser: \(config.defaultHTTPSBundleID)")
}

func hostRuleList() throws {
    let config = try loadShimConfig()
    print("default -> \(config.defaultHTTPSBundleID)")
    if config.rules.isEmpty {
        print("(no host rules)")
        return
    }
    for rule in config.rules.sorted(by: { $0.host < $1.host }) {
        if let path = appPath(for: rule.bundleID) {
            print("\(rule.host) -> \(rule.bundleID) (\(path))")
        } else {
            print("\(rule.host) -> \(rule.bundleID)")
        }
    }
}

func hostRuleAdd(host: String, bundleID: String) throws {
    var config = try loadShimConfig()
    let normalizedHost = host.lowercased()
    config.rules.removeAll { $0.host.lowercased() == normalizedHost }
    config.rules.append(HostRule(host: normalizedHost, bundleID: bundleID))
    try saveShimConfig(config)
    print("Added rule: \(normalizedHost) -> \(bundleID)")
}

func hostRuleRemove(host: String) throws {
    var config = try loadShimConfig()
    let normalizedHost = host.lowercased()
    let before = config.rules.count
    config.rules.removeAll { $0.host.lowercased() == normalizedHost }
    try saveShimConfig(config)
    if config.rules.count == before {
        print("No rule existed for host: \(normalizedHost)")
    } else {
        print("Removed rule: \(normalizedHost)")
    }
}

func hostRuleSetDefault(bundleID: String) throws {
    var config = try loadShimConfig()
    config.defaultHTTPSBundleID = bundleID
    try saveShimConfig(config)
    print("Set default browser bundle ID: \(bundleID)")
}

func buildShimApp() throws {
    let fileManager = FileManager.default
    let cwd = fileManager.currentDirectoryPath
    let sourcePath = "\(cwd)/URLHandlerShim/main.swift"
    guard fileManager.fileExists(atPath: sourcePath) else {
        throw CLIError.notFound("Missing source file: \(sourcePath)")
    }

    let home = fileManager.homeDirectoryForCurrentUser.path
    let appDir = "\(home)/Applications/URLHandlerShim.app"
    let macOSDir = "\(appDir)/Contents/MacOS"
    let resourcesDir = "\(appDir)/Contents/Resources"

    try fileManager.createDirectory(atPath: macOSDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

    let plistPath = "\(appDir)/Contents/Info.plist"
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleDevelopmentRegion</key>
      <string>en</string>
      <key>CFBundleExecutable</key>
      <string>URLHandlerShim</string>
      <key>CFBundleIdentifier</key>
      <string>\(shimBundleID)</string>
      <key>CFBundleInfoDictionaryVersion</key>
      <string>6.0</string>
      <key>CFBundleName</key>
      <string>URLHandlerShim</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>CFBundleShortVersionString</key>
      <string>1.0</string>
      <key>CFBundleVersion</key>
      <string>1</string>
      <key>LSUIElement</key>
      <true/>
      <key>CFBundleURLTypes</key>
      <array>
        <dict>
          <key>CFBundleURLName</key>
          <string>Web URLs</string>
          <key>CFBundleURLSchemes</key>
          <array>
            <string>http</string>
            <string>https</string>
          </array>
        </dict>
      </array>
    </dict>
    </plist>
    """
    try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    process.arguments = [sourcePath, "-O", "-o", "\(macOSDir)/URLHandlerShim"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.io("swiftc failed while building URLHandlerShim.")
    }

    print("Built app: \(appDir)")
}

func registerShimInLaunchServices(appBundleURL: URL) throws {
    let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    guard FileManager.default.fileExists(atPath: lsregisterPath) else {
        return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: lsregisterPath)
    process.arguments = ["-f", appBundleURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.io("Failed to register shim with LaunchServices.")
    }
}

func setHandlerWithRetry(scheme: String, bundleID: String, attempts: Int = 5) -> OSStatus {
    for attempt in 1...attempts {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
        if status == noErr {
            return noErr
        }
        if attempt < attempts {
            Thread.sleep(forTimeInterval: 0.5)
        } else {
            return status
        }
    }
    return -1
}

func installShim() throws {
    try buildShimApp()

    let appBundleURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("URLHandlerShim.app", isDirectory: true)
    guard let bundleID = Bundle(url: appBundleURL)?.bundleIdentifier, bundleID == shimBundleID else {
        throw CLIError.io("Could not read bundle ID from built shim app.")
    }

    try registerShimInLaunchServices(appBundleURL: appBundleURL)

    let statusHTTPS = setHandlerWithRetry(scheme: "https", bundleID: shimBundleID)
    let statusHTTP = setHandlerWithRetry(scheme: "http", bundleID: shimBundleID)
    guard statusHTTPS == noErr, statusHTTP == noErr else {
        let failingStatus = statusHTTPS != noErr ? statusHTTPS : statusHTTP
        if failingStatus == -54 {
            throw CLIError.io(
                "macOS blocked the handler change (OSStatus -54). Approve the system prompt, then rerun: ./url-handler.swift install-shim"
            )
        }
        throw CLIError.setFailed(failingStatus)
    }
    print("Set http/https handler to \(shimBundleID)")
}

func doctor() throws {
    enum CheckState: String {
        case pass = "PASS"
        case warn = "WARN"
        case fail = "FAIL"
    }
    struct Check {
        let state: CheckState
        let message: String
    }

    var checks: [Check] = []
    let fileManager = FileManager.default

    let appBundleURL = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("URLHandlerShim.app", isDirectory: true)
    let appBinaryURL = appBundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent("URLHandlerShim")

    if fileManager.fileExists(atPath: appBundleURL.path) {
        checks.append(Check(state: .pass, message: "Shim app exists at \(appBundleURL.path)"))
    } else {
        checks.append(Check(state: .fail, message: "Shim app missing. Run: ./url-handler.swift build-shim"))
    }

    if fileManager.isExecutableFile(atPath: appBinaryURL.path) {
        checks.append(Check(state: .pass, message: "Shim binary is executable"))
    } else {
        checks.append(Check(state: .fail, message: "Shim binary missing or not executable. Rebuild shim app"))
    }

    let httpHandler = handlerBundleID(for: "http")
    let httpsHandler = handlerBundleID(for: "https")

    if httpHandler == shimBundleID {
        checks.append(Check(state: .pass, message: "http handler is set to shim"))
    } else if let httpHandler {
        checks.append(Check(state: .warn, message: "http handler is \(httpHandler), not shim"))
    } else {
        checks.append(Check(state: .fail, message: "Could not resolve current http handler"))
    }

    if httpsHandler == shimBundleID {
        checks.append(Check(state: .pass, message: "https handler is set to shim"))
    } else if let httpsHandler {
        checks.append(Check(state: .warn, message: "https handler is \(httpsHandler), not shim"))
    } else {
        checks.append(Check(state: .fail, message: "Could not resolve current https handler"))
    }

    let configURL = try shimConfigURL()
    if fileManager.fileExists(atPath: configURL.path) {
        checks.append(Check(state: .pass, message: "Config exists at \(configURL.path)"))
    } else {
        checks.append(Check(state: .warn, message: "Config not found. Run: ./url-handler.swift host-rule init"))
    }

    do {
        let config = try loadShimConfig()
        if appPath(for: config.defaultHTTPSBundleID) != nil {
            checks.append(Check(state: .pass, message: "Default bundle ID is installed: \(config.defaultHTTPSBundleID)"))
        } else {
            checks.append(Check(state: .fail, message: "Default bundle ID is not installed: \(config.defaultHTTPSBundleID)"))
        }

        if config.rules.isEmpty {
            checks.append(Check(state: .warn, message: "No host rules configured"))
        } else {
            checks.append(Check(state: .pass, message: "Host rules configured: \(config.rules.count)"))
            for rule in config.rules.sorted(by: { $0.host < $1.host }) {
                if appPath(for: rule.bundleID) != nil {
                    checks.append(Check(state: .pass, message: "Rule ok: \(rule.host) -> \(rule.bundleID)"))
                } else {
                    checks.append(Check(state: .fail, message: "Rule target app missing: \(rule.host) -> \(rule.bundleID)"))
                }
            }
        }
    } catch {
        checks.append(Check(state: .fail, message: "Config read failed: \(error)"))
    }

    print("URL Handler Doctor")
    for check in checks {
        print("[\(check.state.rawValue)] \(check.message)")
    }

    let failed = checks.contains { $0.state == .fail }
    if failed {
        throw CLIError.io("Doctor found failures.")
    }
}

func handleHostRuleSubcommand(_ args: [String]) throws {
    guard args.count >= 2 else { throw CLIError.usage(usage()) }
    switch args[1] {
    case "init":
        guard args.count == 2 else { throw CLIError.usage(usage()) }
        try hostRuleInit()
    case "list":
        guard args.count == 2 else { throw CLIError.usage(usage()) }
        try hostRuleList()
    case "add":
        guard args.count == 4 else { throw CLIError.usage(usage()) }
        try hostRuleAdd(host: args[2], bundleID: args[3])
    case "remove":
        guard args.count == 3 else { throw CLIError.usage(usage()) }
        try hostRuleRemove(host: args[2])
    case "default":
        guard args.count == 3 else { throw CLIError.usage(usage()) }
        try hostRuleSetDefault(bundleID: args[2])
    default:
        throw CLIError.usage(usage())
    }
}

func openURL(_ rawURL: String) throws {
    guard let url = URL(string: rawURL) else {
        throw CLIError.usage("Invalid URL: \(rawURL)")
    }
    let ok = NSWorkspace.shared.open(url)
    if !ok {
        throw CLIError.notFound("Failed to open URL: \(rawURL)")
    }
    print("Opened: \(rawURL)")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else {
        throw CLIError.usage(usage())
    }

    switch args[0] {
    case "doctor":
        guard args.count == 1 else { throw CLIError.usage(usage()) }
        try doctor()
    case "list":
        guard args.count == 1 else { throw CLIError.usage(usage()) }
        try listHandlers()
    case "host-rule":
        try handleHostRuleSubcommand(args)
    case "build-shim":
        guard args.count == 1 else { throw CLIError.usage(usage()) }
        try buildShimApp()
    case "install-shim":
        guard args.count == 1 else { throw CLIError.usage(usage()) }
        try installShim()
    case "get":
        guard args.count == 2 else { throw CLIError.usage(usage()) }
        try getHandler(for: args[1].lowercased())
    case "set":
        guard args.count == 3 else { throw CLIError.usage(usage()) }
        try setHandler(for: args[1].lowercased(), bundleID: args[2])
    case "open":
        guard args.count == 2 else { throw CLIError.usage(usage()) }
        try openURL(args[1])
    case "-h", "--help", "help":
        print(usage())
    default:
        throw CLIError.usage(usage())
    }
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
