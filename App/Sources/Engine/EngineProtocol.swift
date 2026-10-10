import Foundation

// Wire types for the darkroom-helper protocol. See Engine/helper.c.

struct EngineModule: Decodable, Identifiable, Hashable {
    let key: String          // "op:multi_priority", e.g. "exposure:0"
    let op: String
    let name: String
    let instanceName: String
    var enabled: Bool
    let canDisable: Bool
    var deprecated: Bool? = false
    /// false for modules that can't work on this image (raw-only ones on a
    /// non-raw, such as an Apple-decoded raw); hidden in the inspector
    var applicable: Bool? = true
    /// text settings, shown but not edited (the lens module's camera and lens)
    var text: [String: String]? = nil
    let inHistory: Bool
    let order: Int
    var fields: [EngineField]
    let unsupportedFields: Int

    var id: String { key }
}

struct EngineField: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable { case float, int, bool, `enum` }

    struct Option: Decodable, Hashable {
        let value: Int
        let label: String
    }

    let name: String         // dotted path inside the params struct
    let label: String
    let described: Bool      // false for internal fields darktable doesn't label
    let kind: Kind
    let min: Double?
    let max: Double?
    var value: FieldValue
    let defaultValue: FieldValue
    let options: [Option]?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, label, described, kind, min, max, value, options
        case defaultValue = "default"
    }
}

enum FieldValue: Decodable, Hashable {
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if c.decodeNil() { self = .number(.nan) }
        else { self = .number(try c.decode(Double.self)) }
    }

    var number: Double {
        switch self {
        case .number(let n): n
        case .bool(let b): b ? 1 : 0
        }
    }

    var bool: Bool {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        }
    }

    var json: Any {
        switch self {
        case .number(let n): n
        case .bool(let b): b
        }
    }
}

struct OpenReply: Decodable {
    let width: Int
    let height: Int
    let camera: String
    let maker: String
    let model: String
    let alias: String
    let hadSidecar: Bool
    let sensor: String?      // "bayer", "xtrans", "monochrome" or "linear"
    let modules: [EngineModule]
}

struct StylesReply: Decodable {
    let styles: [String]
}

struct ModulesReply: Decodable {
    let modules: [EngineModule]
}

struct RenderReply: Decodable {
    let width: Int
    let height: Int
    let ms: Int
    let outputProfile: Int   // darktable colour profile type chosen for export
    let processedWidth: Int  // the full-size output, after crop and rotation
    let processedHeight: Int
    let rotateInWidth: Int?  // the size reaching rotate and perspective
    let rotateInHeight: Int?
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
