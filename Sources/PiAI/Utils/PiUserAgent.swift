import Foundation

/// Builds the `pi` User-Agent string.
///
/// Port of upstream `utils/pi-user-agent.ts`. The TypeScript original reports
/// the Node/Bun OS platform, release and arch; the Swift port reports the
/// host OS name, major/minor version, and CPU architecture, e.g.
/// `pi (macOS 14.5; arm64)`.
public enum PiUserAgent {
    public static var current: String {
        "pi (\(platformName) \(platformVersion); \(architecture))"
    }

    private static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(Linux)
        return "Linux"
        #elseif os(Windows)
        return "Windows"
        #else
        return "unknown"
        #endif
    }

    private static var platformVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(arm)
        return "arm"
        #elseif arch(i386)
        return "i386"
        #else
        return "unknown"
        #endif
    }
}
