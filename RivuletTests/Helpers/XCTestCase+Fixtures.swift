//
//  XCTestCase+Fixtures.swift
//  RivuletTests
//
//  Helpers for loading test fixture files
//

import XCTest

extension XCTestCase {

    /// Load a fixture file from the test bundle as Data
    /// - Parameters:
    ///   - name: The fixture file name (without extension)
    ///   - ext: The file extension
    ///   - subdirectory: Optional subdirectory within Fixtures folder
    /// - Returns: The file contents as Data
    /// - Throws: Error if file cannot be found or read
    func loadFixture(_ name: String, extension ext: String, subdirectory: String? = nil) throws -> Data {
        let bundle = Bundle(for: type(of: self))

        // Build the subdirectory path
        let directory: String?
        if let subdirectory = subdirectory {
            directory = "Fixtures/\(subdirectory)"
        } else {
            directory = "Fixtures"
        }

        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: directory) else {
            throw FixtureError.notFound(name: name, ext: ext, subdirectory: directory)
        }

        return try Data(contentsOf: url)
    }

    /// Load a fixture file from the test bundle as String
    /// - Parameters:
    ///   - name: The fixture file name (without extension)
    ///   - ext: The file extension
    ///   - subdirectory: Optional subdirectory within Fixtures folder
    /// - Returns: The file contents as String
    /// - Throws: Error if file cannot be found, read, or decoded
    func loadFixtureString(_ name: String, extension ext: String, subdirectory: String? = nil) throws -> String {
        let data = try loadFixture(name, extension: ext, subdirectory: subdirectory)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FixtureError.invalidEncoding(name: name)
        }
        return string
    }

    /// Load a fixture file and decode as JSON
    /// - Parameters:
    ///   - name: The fixture file name (without extension)
    ///   - type: The type to decode into
    ///   - subdirectory: Optional subdirectory within Fixtures folder
    /// - Returns: The decoded object
    /// - Throws: Error if file cannot be found, read, or decoded
    func loadFixtureJSON<T: Decodable>(_ name: String, as type: T.Type, subdirectory: String? = nil) throws -> T {
        let data = try loadFixture(name, extension: "json", subdirectory: subdirectory)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Fixture Errors

enum FixtureError: LocalizedError {
    case notFound(name: String, ext: String, subdirectory: String?)
    case invalidEncoding(name: String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name, let ext, let subdirectory):
            let path = subdirectory.map { "\($0)/" } ?? ""
            return "Fixture not found: \(path)\(name).\(ext)"
        case .invalidEncoding(let name):
            return "Fixture has invalid encoding: \(name)"
        }
    }
}

// MARK: - Test Data Builders

/// Factory for creating test MediaTrack instances
enum MediaTrackFactory {

    /// Create a basic audio track
    static func audioTrack(
        id: Int = 1,
        name: String = "English",
        language: String? = "English",
        languageCode: String? = "eng",
        codec: String? = "aac",
        isDefault: Bool = false,
        channels: Int? = 2
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "isDefault": isDefault,
            "isForced": false,
            "isHearingImpaired": false
        ]
        if let language = language { dict["language"] = language }
        if let languageCode = languageCode { dict["languageCode"] = languageCode }
        if let codec = codec { dict["codec"] = codec }
        if let channels = channels { dict["channels"] = channels }
        return dict
    }

    /// Create a basic subtitle track
    static func subtitleTrack(
        id: Int = 1,
        name: String = "English",
        language: String? = "English",
        languageCode: String? = "eng",
        codec: String? = "srt",
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "isDefault": isDefault,
            "isForced": isForced,
            "isHearingImpaired": isHearingImpaired
        ]
        if let language = language { dict["language"] = language }
        if let languageCode = languageCode { dict["languageCode"] = languageCode }
        if let codec = codec { dict["codec"] = codec }
        return dict
    }
}
