import Foundation

enum NetworkTools {

    static let pingSpec = ToolSpec(
        name: "ping",
        description: "Ping a host to check if it's reachable and measure latency.",
        properties: ["host": .init(type: "string", description: "Hostname or IP address")],
        required: ["host"]
    )

    static let dnsLookupSpec = ToolSpec(
        name: "dns_lookup",
        description: "Look up DNS records for a domain. Shows A, AAAA, MX, CNAME, and NS records.",
        properties: ["domain": .init(type: "string", description: "Domain name to look up")],
        required: ["domain"]
    )

    static let portCheckSpec = ToolSpec(
        name: "port_check",
        description: "Check if a specific port is open on a host.",
        properties: [
            "host": .init(type: "string", description: "Hostname or IP address"),
            "port": .init(type: "string", description: "Port number to check"),
        ],
        required: ["host", "port"]
    )

    static let httpCheckSpec = ToolSpec(
        name: "http_check",
        description: "Check HTTP response from a URL: status code, headers, redirect chain, response time. Use for debugging APIs or checking if a site is up.",
        properties: ["url": .init(type: "string", description: "URL to check")],
        required: ["url"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(pingSpec) { args in
            await ping(host: args["host"] as? String ?? "")
        }
        await registry.register(dnsLookupSpec) { args in
            await dnsLookup(domain: args["domain"] as? String ?? "")
        }
        await registry.register(portCheckSpec) { args in
            await portCheck(
                host: args["host"] as? String ?? "",
                port: args["port"] as? String ?? ""
            )
        }
        await registry.register(httpCheckSpec) { args in
            await httpCheck(url: args["url"] as? String ?? "")
        }
    }

    // MARK: - Ping

    static func ping(host: String) async -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty host" }
        // Sanitize: only allow alphanumeric, dots, dashes, colons (IPv6)
        let safe = trimmed.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(.init(charactersIn: ".-:")).contains($0)
        }
        guard safe else { return "Error: invalid host" }

        return await shell("ping -c 4 -t 5 '\(trimmed)' 2>&1", timeout: 10)
    }

    // MARK: - DNS Lookup

    static func dnsLookup(domain: String) async -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty domain" }
        let safe = trimmed.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(.init(charactersIn: ".-")).contains($0)
        }
        guard safe else { return "Error: invalid domain" }

        var results: [String] = ["DNS records for \(trimmed)", String(repeating: "─", count: 35)]

        // A records
        let a = await shell("dig +short A '\(trimmed)' 2>/dev/null || nslookup '\(trimmed)' 2>/dev/null | grep 'Address:' | tail -n+2", timeout: 8)
        if !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append("A Records:\n\(indent(a))")
        }

        // AAAA records
        let aaaa = await shell("dig +short AAAA '\(trimmed)' 2>/dev/null", timeout: 5)
        if !aaaa.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append("AAAA Records:\n\(indent(aaaa))")
        }

        // MX records
        let mx = await shell("dig +short MX '\(trimmed)' 2>/dev/null", timeout: 5)
        if !mx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append("MX Records:\n\(indent(mx))")
        }

        // CNAME
        let cname = await shell("dig +short CNAME '\(trimmed)' 2>/dev/null", timeout: 5)
        if !cname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append("CNAME:\n\(indent(cname))")
        }

        // NS
        let ns = await shell("dig +short NS '\(trimmed)' 2>/dev/null", timeout: 5)
        if !ns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append("NS Records:\n\(indent(ns))")
        }

        return results.joined(separator: "\n")
    }

    // MARK: - Port Check

    static func portCheck(host: String, port: String) async -> String {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, let portNum = Int(trimmedPort), portNum > 0, portNum <= 65535 else {
            return "Error: invalid host or port"
        }

        let result = await shell("nc -z -w 3 '\(trimmedHost)' \(portNum) 2>&1; echo \"EXIT:$?\"", timeout: 8)
        if result.contains("EXIT:0") {
            return "Port \(portNum) on \(trimmedHost) is OPEN"
        } else {
            return "Port \(portNum) on \(trimmedHost) is CLOSED or unreachable"
        }
    }

    // MARK: - HTTP Check

    static func httpCheck(url urlString: String) async -> String {
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            return "Error: URL must start with http:// or https://"
        }

        let result = await shell("""
        curl -s -o /dev/null -w 'Status: %{http_code}\\nTime: %{time_total}s\\nRedirects: %{num_redirects}\\nFinal URL: %{url_effective}\\nRemote IP: %{remote_ip}\\nSize: %{size_download} bytes\\nContent-Type: %{content_type}' -L --max-time 10 '\(urlString.replacingOccurrences(of: "'", with: ""))' 2>&1
        """, timeout: 15)

        return "HTTP Check: \(urlString)\n\(result)"
    }

    // MARK: - Helpers

    private static func shell(_ command: String, timeout: TimeInterval) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                return "Error: command timed out after \(Int(timeout))s"
            }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private static func indent(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
