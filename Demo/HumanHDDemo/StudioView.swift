import SwiftUI
import HumanCore
import HumanKit

struct StudioView: View {
    @Environment(Studio.self) private var studio
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var open = false

    var body: some View {
        @Bindable var s = studio
        NavigationStack {
            Form {
                Section {
                    Button(open ? "Close stage" : "Open stage") {
                        Task {
                            if open { await dismissSpace(); open = false }
                            else { open = (await openSpace(id: "stage")) == .opened }
                        }
                    }
                    if studio.building { ProgressView("Building character") } else if !studio.stats.isEmpty { Text(studio.stats).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Body") {
                    slider("Gender", $s.spec.shape.gender, 0...1)
                    slider("Age", $s.spec.shape.age, 12...85)
                    slider("Muscle", $s.spec.shape.muscle, 0...1)
                    slider("Weight", $s.spec.shape.weight, 0...1)
                    slider("Height", $s.spec.shape.height, 0...1)
                    slider("Proportions", $s.spec.shape.proportions, 0...1)
                }
                Section("Skin") {
                    slider("Tone", $s.spec.appearance.skin.tone, 0...1)
                    slider("Undertone", $s.spec.appearance.skin.undertone, -1...1)
                    slider("Flush", $s.spec.appearance.skin.flush, 0...1)
                    slider("Freckles", $s.spec.appearance.detail.freckles, 0...1)
                    slider("Stubble (mm)", $s.spec.appearance.detail.stubble, 0...3)
                }
                Section("Hair and eyes") {
                    Picker("Hair", selection: Binding(get: { studio.spec.hair.kind.rawValue + "-" + String(format: "%.2f", studio.spec.hair.length) }, set: { key in
                        if let h = HairStyle.presets.values.first(where: { $0.kind.rawValue + "-" + String(format: "%.2f", $0.length) == key }) { studio.spec.hair = h; studio.rebuild() }
                    })) {
                        ForEach(HairStyle.presets.sorted(by: { $0.key < $1.key }), id: \.key) { k, h in Text(k.capitalized).tag(h.kind.rawValue + "-" + String(format: "%.2f", h.length)) }
                    }
                    ColorRow(title: "Hair color", options: [0x0E0B09, 0x2A1A10, 0x4A3020, 0x7A5A38, 0xB08A5A, 0x8A4A2A, 0xB8B4AE]) { studio.spec.appearance.hairColor = LinearColor(hex: $0); studio.rebuild() }
                    Picker("Eyes", selection: Binding(get: { eyeName(studio.spec.appearance.eyes) }, set: { n in studio.spec.appearance.eyes = eyePresets[n] ?? .brown; studio.rebuild() })) {
                        ForEach(eyePresets.keys.sorted(), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section("Outfit") {
                    Picker("Outfit", selection: Binding(get: { Outfit.presets.first(where: { $0.value == studio.spec.outfit })?.key ?? "none" }, set: { k in studio.spec.outfit = Outfit.presets[k] ?? .none; studio.rebuild() })) {
                        Text("None").tag("none")
                        ForEach(Outfit.presets.keys.sorted(), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section("Motion") {
                    Picker("Move", selection: $s.speed) { Text("Idle").tag(Float(0)); Text("Walk").tag(Float(1.3)); Text("Run").tag(Float(3.4)) }.pickerStyle(.segmented)
                    Picker("FacialExpression", selection: $s.expression) { ForEach(FacialExpression.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Toggle("Talking", isOn: $s.talking)
                }
                Section("Crowd") {
                    Stepper("Extra people: \(studio.crowd)", value: $s.crowd, in: 0...40, step: 4)
                    Button("Randomize character") { studio.spec = HumanSpec.random(seed: UInt64.random(in: 1...10_000)); studio.rebuild() }
                }
                Section { Button("Apply body changes") { studio.rebuild() } }
            }
            .navigationTitle("HumanHD")
        }
        .task {
            // Launch argument for captures: -autoStage YES
            if UserDefaults.standard.bool(forKey: "autoStage") && !open { open = (await openSpace(id: "stage")) == .opened }
        }
    }

    let eyePresets: [String: EyeLook] = ["brown": .brown, "dark brown": .darkBrown, "hazel": .hazel, "green": .green, "blue": .blue, "grey": .grey]
    func eyeName(_ e: EyeLook) -> String { eyePresets.first(where: { $0.value == e })?.key ?? "brown" }

    func slider(_ title: String, _ v: Binding<Float>, _ r: ClosedRange<Float>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: v, in: r) { editing in if !editing { studio.rebuild() } }
        }
    }
}

struct ColorRow: View {
    let title: String
    let options: [UInt32]
    let pick: (UInt32) -> Void
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(options, id: \.self) { hex in
                Circle().fill(Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255))
                    .frame(width: 26, height: 26).onTapGesture { pick(hex) }
            }
        }
    }
}
