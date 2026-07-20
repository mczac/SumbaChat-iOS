//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// SumbaChat hosts are always `https://{subdomain}.{brandingBaseDomain}`.
/// Deployment values come from gitignored `NCAppBrandingLocal.h` (via `NCAppBranding`).
enum SumbaServerConfiguration {
    static var baseDomain: String { brandingBaseDomain }
    static var defaultSubdomain: String { brandingDefaultSubdomain }
    static var domainSuffix: String { ".\(baseDomain)" }
    static var supportEmail: String { brandingSupportEmail }

    /// Shared copy for HTTP 429 on login, forgot-password, and delete-account.
    static let tooManyAttemptsMessage = NSLocalizedString(
        "Too many attempts. Wait a few minutes and try again.",
        comment: ""
    )

    private static let lastSubdomainKey = "sumbaLastServerSubdomain"

    static var preferredSubdomain: String {
        if let stored = UserDefaults.standard.string(forKey: lastSubdomainKey),
           let normalized = normalizeSubdomain(stored) {
            return normalized
        }
        return defaultSubdomain
    }

    static func rememberSubdomain(_ subdomain: String) {
        guard let normalized = normalizeSubdomain(subdomain) else { return }
        UserDefaults.standard.set(normalized, forKey: lastSubdomainKey)
    }

    /// Accepts a bare subdomain, `subdomain.base`, or a full `https://…` URL and returns the 3rd-level label.
    static func normalizeSubdomain(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("https://") {
            value = String(value.dropFirst("https://".count))
        } else if value.hasPrefix("http://") {
            value = String(value.dropFirst("http://".count))
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if value.hasSuffix(domainSuffix) {
            value = String(value.dropLast(domainSuffix.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
        guard !value.isEmpty else { return nil }
        // Single DNS label: letters/digits/hyphen, 1…63 chars, no leading/trailing hyphen.
        let pattern = #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func serverURL(subdomain: String) -> String? {
        guard let normalized = normalizeSubdomain(subdomain) else { return nil }
        return "https://\(normalized).\(baseDomain)"
    }

    static func subdomain(fromServerURL serverURL: String) -> String? {
        normalizeSubdomain(serverURL)
    }

    /// Display host without scheme, e.g. `{subdomain}.{baseDomain}`.
    static func displayHost(fromServerURL serverURL: String) -> String {
        var host = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("https://") {
            host = String(host.dropFirst("https://".count))
        } else if host.hasPrefix("http://") {
            host = String(host.dropFirst("http://".count))
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        return host
    }

    /// Result of probing Nextcloud `status.php` (no auth).
    enum ServerStatus: Equatable {
        case online
        case maintenance
        case offline
    }

    /// Lightweight status via Nextcloud `status.php` (no auth).
    /// Parses `maintenance` / `needsDbUpgrade` / `installed` — not just HTTP success.
    static func checkServerStatus(serverURL: String, completion: @escaping (ServerStatus) -> Void) {
        let trimmed = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/status.php") else {
            DispatchQueue.main.async { completion(.offline) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(NCAppBranding.userAgentForLogin(), forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = Self.parseStatusResponse(data: data, response: response)
            DispatchQueue.main.async {
                completion(status)
            }
        }.resume()
    }

    private static func parseStatusResponse(data: Data?, response: URLResponse?) -> ServerStatus {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .offline
        }

        let installed = json["installed"] as? Bool ?? true
        if !installed {
            return .offline
        }

        let maintenance = json["maintenance"] as? Bool ?? false
        let needsDbUpgrade = json["needsDbUpgrade"] as? Bool ?? false
        if maintenance || needsDbUpgrade {
            return .maintenance
        }

        return .online
    }
}
