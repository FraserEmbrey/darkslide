import SwiftUI

struct SettingsView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Default tone mapper", selection: $model.toneMapper) {
                    ForEach(ToneMapper.allCases) { tm in
                        VStack(alignment: .leading) {
                            Text(tm.title)
                            Text(tm.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(tm)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Used for photos without an existing edit. Photos you've already edited keep their tone mapper.")
            }

            Section {
                Picker("Graphics processing", selection: $model.gpuBackend) {
                    ForEach(GPUBackend.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Metal runs darktable's GPU code on Apple's current graphics framework. Apple OpenCL is the deprecated path darktable normally uses on a Mac; CPU only skips the GPU. All three give the same result.")
            }

            Section {
                Picker("Background", selection: $model.canvasBackground) {
                    ForEach(CanvasBackground.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Neutral grey is best for judging tones and colour, as in darktable.")
            }

            Section {
                Toggle("Correct lens distortion and vignetting for new photos", isOn: $model.lensCorrectionForNewPhotos)
            } footer: {
                Text("Uses the correction data the camera stores in the raw file where there is some (Sony, Fujifilm, Olympus and others), otherwise the Lensfun lens database.")
            }

            Section {
                Toggle("Use automatic exposure for new photos", isOn: $model.autoExposureForNewPhotos)
            } footer: {
                Text("Sets darktable's exposure module to automatic on photos without an existing edit. It aims a chosen percentile of the image at a target level; both stay adjustable.")
            }

            Section {
                Picker("Camera styles", selection: $model.cameraStyleMode) {
                    ForEach(CameraStyleMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("darktable's camera styles approximate each camera's own JPEG look. One is offered only when darktable has a style for that camera or its series, only for raws, and only for photos without an existing edit. The suggestion banner has the same choice in its … menu.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
