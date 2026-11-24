import AppKit
import SwiftUI
import WorkLightCore

struct SettingsView: View {
    @State var draft: LampSettings
    @State var hasStoredToken: Bool
    @State private var tokenInput: String = ""
    @State private var tokenError: String?

    let save: (LampSettings, String?) -> String?
    let clearToken: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Home Assistant") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Base URL") {
                        TextField("http://homeassistant.local:8123", text: $draft.endpoint.baseURLString)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Light Entity") {
                        TextField("light.office_lamp", text: $draft.endpoint.entityID)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Access Token") {
                        HStack(spacing: 6) {
                            SecureField(
                                hasStoredToken ? "Stored in Keychain (leave blank to keep)" : "Paste Long-Lived Access Token",
                                text: $tokenInput
                            )
                            .textFieldStyle(.roundedBorder)
                            if hasStoredToken {
                                Button("Clear") {
                                    clearToken()
                                    hasStoredToken = false
                                    tokenInput = ""
                                }
                            }
                        }
                    }
                    Toggle("Use Yeelight / Xiaomi Miot Color & Day effects", isOn: $draft.endpoint.useMiotEffects)
                        .font(.callout)
                }
                .padding(.vertical, 6)
            }

            GroupBox("On-Air Signals") {
                VStack(spacing: 10) {
                    slider("Busy (Red)", icon: "minus.circle.fill", tint: .red, value: $draft.busyBrightness, range: 1...100, unit: "%")
                    slider("Available", icon: "checkmark.circle.fill", tint: .green, value: $draft.freeBrightness, range: 1...100, unit: "%")
                }
                .padding(.vertical, 6)
            }

            GroupBox("Automatic Call Detection (Local)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Switch to Busy automatically when microphone is active", isOn: $draft.autoBusyOnMicrophone)
                    if draft.autoBusyOnMicrophone {
                        Picker("After call ends", selection: $draft.callReturnBehavior) {
                            ForEach(CallReturnBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        Text("Reads CoreAudio hardware active state only — no audio is captured and no microphone permission is required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            GroupBox("Normal Light") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Mode", selection: $draft.normalStyle) {
                        Text("White").tag(LampSettings.NormalStyle.white)
                        Text("Color").tag(LampSettings.NormalStyle.color)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.normalStyle) { _, style in
                        if style == .white && draft.normalRGB == 0 { draft.normalRGB = RGB.violet.packed }
                    }
                    slider("Brightness", icon: "sun.max", value: $draft.normalBrightness, range: 1...100, unit: "%")
                    if draft.normalStyle == .white {
                        slider("Color Temp", icon: "thermometer.medium", value: $draft.kelvin, range: 1700...6500, step: 100, unit: " K")
                    } else {
                        ColorPicker("Lamp Color", selection: color, supportsOpacity: false)
                    }
                }
                .padding(.vertical, 6)
            }

            HStack {
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    tokenError = save(draft, tokenInput)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var canSave: Bool {
        draft.isValid && draft.endpoint.isConfigured
    }

    private var validationMessage: String? {
        if let tokenError { return tokenError }
        if draft.endpoint.normalizedBaseURL == nil { return "Enter a valid http:// or https:// Home Assistant URL." }
        if draft.endpoint.normalizedEntityID == nil { return "Entity ID must look like light.office_lamp." }
        if !draft.isValid { return "Choose a color brighter than black." }
        return nil
    }

    private func slider(
        _ title: String, icon: String, tint: Color = .secondary, value: Binding<Int>,
        range: ClosedRange<Int>, step: Double = 1, unit: String
    ) -> some View {
        let binding = Binding<Double>(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title).frame(width: 96, alignment: .leading).accessibilityHidden(true)
            Slider(value: binding, in: Double(range.lowerBound)...Double(range.upperBound), step: step) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue("\(value.wrappedValue)\(unit)")
            Text("\(value.wrappedValue)\(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var color: Binding<Color> {
        Binding(
            get: {
                let channels = RGB(packed: draft.normalRGB)?.channels ?? [0, 0, 0]
                return Color(red: Double(channels[0]) / 255, green: Double(channels[1]) / 255, blue: Double(channels[2]) / 255)
            },
            set: { value in
                guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                    Int((min(max($0, 0), 1) * 255).rounded())
                }
                draft.normalRGB = RGB(channels: channels)?.packed ?? 0
            }
        )
    }
}
