// Written by Scripts/publish-models.sh: the models published for download
// (ModelStore), as zipped compiled models on the GitHub release `release`.
enum ModelManifest {
    static let release = ""
    static let models: [String: (bytes: Int, sha256: String)] = [:]
}
