//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum SumbaDeleteAccountResult {
    case deleted
    case failed(message: String)
}

enum SumbaDeletePasswordVerifyResult {
    case success
    case incorrectPassword
    case rateLimited
    case failed(message: String)
}

/// Self-delete via Nextcloud Drop Account app:
/// `DELETE /ocs/v2.php/apps/drop_account/api/v1/account`
/// Single-step deletion (no email confirmation). Strict password confirmation uses Basic auth.
enum SumbaDeleteAccountService {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    static func verifyPassword(
        account: TalkAccount,
        password: String,
        completion: @escaping (SumbaDeletePasswordVerifyResult) -> Void
    ) {
        let accountId = account.accountId
        NCLog.log("Delete account: verifying password for \(accountId)")

        let base = account.server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/ocs/v2.php/cloud/user") else {
            NCLog.log("Delete account: verify failed — invalid server URL for \(accountId)")
            DispatchQueue.main.async {
                completion(.failed(message: NSLocalizedString("Invalid server URL.", comment: "")))
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NCAppBranding.userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue(basicAuthHeader(user: account.user, password: password), forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    NCLog.log("Delete account: verify network error for \(accountId) — \(error.localizedDescription)")
                    completion(.failed(message: error.localizedDescription))
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200...299:
                    NCLog.log("Delete account: password verified for \(accountId) (HTTP \(code))")
                    completion(.success)
                case 429:
                    NCLog.log("Delete account: verify rate-limited for \(accountId) (HTTP 429)")
                    completion(.rateLimited)
                case 401, 403:
                    NCLog.log("Delete account: incorrect password for \(accountId) (HTTP \(code))")
                    completion(.incorrectPassword)
                default:
                    NCLog.log("Delete account: verify failed for \(accountId) (HTTP \(code))")
                    completion(.incorrectPassword)
                }
            }
        }.resume()
    }

    static func deleteAccount(
        account: TalkAccount,
        password: String,
        completion: @escaping (SumbaDeleteAccountResult) -> Void
    ) {
        let accountId = account.accountId
        NCLog.log("Delete account: calling Drop Account API for \(accountId)")

        let base = account.server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/ocs/v2.php/apps/drop_account/api/v1/account") else {
            NCLog.log("Delete account: Drop Account URL invalid for \(accountId)")
            DispatchQueue.main.async {
                completion(.failed(message: NSLocalizedString("Invalid server URL.", comment: "")))
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NCAppBranding.userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue(basicAuthHeader(user: account.user, password: password), forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    NCLog.log("Delete account: Drop Account network error for \(accountId) — \(error.localizedDescription)")
                    completion(.failed(message: error.localizedDescription))
                    return
                }

                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let message = ocsMessage(from: data)

                switch code {
                // 200/202 = deleted. 201 was the old email-confirm response; treat as deleted too
                // now that the server performs single-step deletion.
                case 200, 201, 202:
                    NCLog.log("Delete account: Drop Account succeeded for \(accountId) (HTTP \(code))")
                    completion(.deleted)
                case 429:
                    NCLog.log("Delete account: Drop Account rate-limited for \(accountId) (HTTP 429)")
                    completion(.failed(message: SumbaServerConfiguration.tooManyAttemptsMessage))
                case 401, 403:
                    NCLog.log("Delete account: Drop Account auth failed for \(accountId) (HTTP \(code))")
                    completion(.failed(message: message ?? NSLocalizedString("Incorrect password or deletion not allowed.", comment: "")))
                case 404:
                    NCLog.log("Delete account: Drop Account app missing for \(accountId) (HTTP 404)")
                    completion(.failed(message: NSLocalizedString(
                        "Account deletion is not available on this server.",
                        comment: "Drop Account app missing"
                    )))
                default:
                    NCLog.log("Delete account: Drop Account failed for \(accountId) (HTTP \(code))")
                    completion(.failed(message: message ?? String(
                        format: NSLocalizedString("Couldn’t delete account (error %d).", comment: ""),
                        code
                    )))
                }
            }
        }.resume()
    }

    private static func basicAuthHeader(user: String, password: String) -> String {
        let credentials = "\(user):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    private static func ocsMessage(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = json["ocs"] as? [String: Any] else {
            return nil
        }

        if let dataDict = ocs["data"] as? [String: Any],
           let message = dataDict["message"] as? String,
           !message.isEmpty {
            return message
        }

        if let meta = ocs["meta"] as? [String: Any],
           let message = meta["message"] as? String,
           !message.isEmpty {
            return message
        }

        return nil
    }
}
