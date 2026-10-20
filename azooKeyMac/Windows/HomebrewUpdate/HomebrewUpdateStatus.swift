import Foundation

struct HomebrewUpdateRequest: Codable, Equatable {
    let jobID: String
    let bundlePath: String
    let bundleVersion: String
    let parentPID: Int
    let language: String

    var isValid: Bool {
        jobID.count == 36 && UUID(uuidString: jobID) != nil &&
        bundlePath.hasPrefix("/") && !bundlePath.contains("\n") && !bundlePath.contains("\r") &&
        HomebrewUpdateVersion(bundleVersion) != nil && parentPID > 1 && Int32(exactly: parentPID) != nil &&
        ["ja", "en"].contains(language)
    }
}

struct HomebrewUpdateVersion: Comparable {
    private let components: [Int]

    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else {
            return nil
        }
        var numbers: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
                  field.count == 1 || !field.hasPrefix("0"), let number = Int(field) else {
                return nil
            }
            numbers.append(number)
        }
        components = numbers
    }

    static func < (left: Self, right: Self) -> Bool {
        left.components.lexicographicallyPrecedes(right.components)
    }
}

enum HomebrewUpdateFailure: String, Codable {
    case unsupported, noHomebrew, unmanaged, changedInstallation, checkFailed, updateFailed
    case verificationFailed, restartFailed, interrupted, invalidStatus, launchFailed, preparationFailed

    var messageKey: String { "support.update.failure." + rawValue }
}

struct HomebrewUpdateStatus: Decodable, Equatable {
    enum Phase: String, Decodable {
        case checking, updating, upToDate, updated, restarting, restarted, failed

        var isFinished: Bool { [.upToDate, .restarted, .failed].contains(self) }

        func canFollow(_ previous: Self) -> Bool {
            if self == previous {
                return true
            }
            guard !previous.isFinished else {
                return false
            }
            switch (previous, self) {
            case (_, .failed), (.checking, _), (.updating, .upToDate), (.updating, .updated), (.updating, .restarting),
                 (.updating, .restarted), (.updated, .restarting), (.updated, .restarted), (.restarting, .restarted):
                return true
            default:
                return false
            }
        }
    }

    let jobID: String
    let phase: Phase
    let code: String
    let installedVersion: String
    let targetVersion: String
    let helperPID: Int

    func isValid(for request: HomebrewUpdateRequest, previous: Self?) -> Bool {
        guard request.isValid, jobID == request.jobID, helperPID > 1, Int32(exactly: helperPID) != nil, helperPID != request.parentPID,
              installedVersion.isEmpty || HomebrewUpdateVersion(installedVersion) != nil,
              targetVersion.isEmpty || HomebrewUpdateVersion(targetVersion) != nil else {
            return false
        }
        if let previous, previous.helperPID != helperPID || !phase.canFollow(previous.phase) {
            return false
        }
        if phase == .failed {
            // Only the helper's fixed failure codes may cross the file boundary.
            return ["unsupported", "noHomebrew", "unmanaged", "changedInstallation", "checkFailed",
                    "updateFailed", "verificationFailed", "restartFailed", "interrupted"].contains(code)
        }
        guard code.isEmpty else {
            return false
        }
        switch phase {
        case .checking, .updating:
            return true
        case .upToDate:
            return installedVersion == request.bundleVersion && targetVersion == request.bundleVersion
        case .updated, .restarting, .restarted:
            guard let installed = HomebrewUpdateVersion(installedVersion),
                  let current = HomebrewUpdateVersion(request.bundleVersion) else {
                return false
            }
            return installedVersion == targetVersion && installed > current
        case .failed:
            return false
        }
    }

    var messageKey: String {
        if phase == .failed, let failure = HomebrewUpdateFailure(rawValue: code) {
            return failure.messageKey
        }
        return "support.update." + phase.rawValue
    }
}

struct HomebrewUpdateJob {
    let request: HomebrewUpdateRequest
    let directory: URL
    let createdAt: Date
}
