// Written by Scripts/publish-models.sh: the models published for download
// (ModelStore), as zipped compiled models on the GitHub release `release`.
enum ModelManifest {
    static let release = "models-2"
    static let models: [String: (bytes: Int, sha256: String)] = [
        "RawDenoise": (bytes: 28853596, sha256: "7861a24b520c88dc6c7ea41d87a8abb0e2721ba895897310c92c61a6eee2b156"),
        "RescueFocus": (bytes: 48308275, sha256: "54e2c2fe7adf7670fbf3957c9693117e710156ab4635f2a6e4f3b7f0fdf5e892"),
        "RescueMotion": (bytes: 48325032, sha256: "2aca7b5430d3616bfdc0a4c26a1c4923867f4b8718dcd737e7758f6c37dad27e"),
        "RemoveObjects": (bytes: 94983042, sha256: "c00f604bac6a8f99fd0dd1a2717e72836ad4f250c6a272797fce9f6b377b7f95"),
    ]
}
