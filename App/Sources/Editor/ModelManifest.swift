// Written by Scripts/publish-models.sh: the models published for download
// (ModelStore), as zipped compiled models on the GitHub release `release`.
enum ModelManifest {
    static let release = "models-1"
    static let models: [String: (bytes: Int, sha256: String)] = [
        "RawDenoise": (bytes: 28853595, sha256: "e7791f13f1d16e85c72b3fbdc0a6517b3b6458d024d3f12c03c7f59010b43f2a"),
        "RescueFocus": (bytes: 48308274, sha256: "17eee93cd7f326676876487e80ac4728b4be7e924dcba907d8a4df92a5f214be"),
        "RescueMotion": (bytes: 48325030, sha256: "263b61436ffad245a95d5bdad5f370e591088d5c299553f285e41a85ee89ed67"),
    ]
}
