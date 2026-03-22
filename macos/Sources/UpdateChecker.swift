import Foundation
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "UpdateChecker")

let appVersion = "0.1.4"

final class UpdateChecker {
    private let owner = "HibiZA"
    private let repo = "LocalPort"
    private var timer: Timer?

    var onUpdateAvailable: ((String) -> Void)?

    private(set) var latestVersion: String?
    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return compare(latest, isNewerThan: appVersion)
    }

    var releaseURL: URL? {
        guard let tag = latestVersion else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/v\(tag)")
    }

    func startChecking(interval: TimeInterval = 3600) {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                logger.debug("Update check failed: \(error.localizedDescription)")
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                logger.debug("Update check: could not parse response")
                return
            }

            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            logger.info("Latest release: \(version), current: \(appVersion)")

            DispatchQueue.main.async {
                self.latestVersion = version
                if self.updateAvailable {
                    self.onUpdateAvailable?(version)
                }
            }
        }.resume()
    }

    private func compare(_ a: String, isNewerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va > vb { return true }
            if va < vb { return false }
        }
        return false
    }
}
