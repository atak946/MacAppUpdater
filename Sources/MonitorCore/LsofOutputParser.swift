import Foundation

/// Parses `lsof -F pPn` machine output into listening ports.
enum LsofOutputParser {
    /// Each line is one field: `p<pid>`, `P<protocol>`, `n<name>`; other fields are ignored.
    /// A file set ends with its `n` line. Wildcard ports, connected peers and duplicates are dropped.
    static func parse(_ output: String) -> [ListeningPort] {
        var pid: Int32?
        var transport: String?
        var seen: Set<ListeningPort> = []
        var ports: [ListeningPort] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); transport = nil
            case "P": transport = value.uppercased()
            case "n":
                guard let pid, let transport, let endpoint = endpoint(fromName: value) else { continue }
                let port = ListeningPort(pid: pid, port: endpoint.port, transport: transport, address: endpoint.address)
                if seen.insert(port).inserted { ports.append(port) }
            default: continue
            }
        }
        return ports.sorted { ($0.port, $0.transport, $0.pid) < ($1.port, $1.transport, $1.pid) }
    }

    /// `127.0.0.1:8080`, `*:5353`, `[::1]:631`, `[fe80:4::1]:123`, `a:1->b:2` (local side only).
    static func endpoint(fromName name: String) -> (address: String, port: UInt16)? {
        let local = name.components(separatedBy: "->")[0]
        guard let colon = local.lastIndex(of: ":") else { return nil }
        guard let port = UInt16(local[local.index(after: colon)...]), port > 0 else { return nil }
        var address = String(local[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        return address.isEmpty ? nil : (address, port)
    }
}
