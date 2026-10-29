import Foundation

/// Lists listening TCP sockets and bound UDP sockets by running `lsof` (no shell).
/// Without root, only the current user's processes are visible.
public struct LsofPortScanner: PortScanning {
    static let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
    static let arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpPn"]
    static let timeout: TimeInterval = 3

    public init() {}

    public func listeningPorts() async -> [ListeningPort] {
        guard let output = await ToolOutputRunner.run(Self.executable, arguments: Self.arguments, timeout: Self.timeout) else {
            return []
        }
        return LsofOutputParser.parse(output)
    }
}
