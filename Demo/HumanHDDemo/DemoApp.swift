import SwiftUI
import RealityKit
import RealKit
import HumanCore
import HumanKit

@main
struct HumanHDDemoApp: App {
    @State private var studio = Studio()
    @State private var style: ImmersionStyle = .mixed

    init() { Human.setup(.balanced) }

    var body: some SwiftUI.Scene {
        WindowGroup {
            StudioView().environment(studio)
        }
        .defaultSize(width: 520, height: 820)

        ImmersiveSpace(id: "stage") {
            StageView().environment(studio)
        }
        .immersionStyle(selection: $style, in: .mixed, .full)
    }
}

/// Shared state between the menu window and the immersive stage.
@MainActor @Observable
final class Studio {
    var spec = HumanSpec().with {
        $0.shape = .averageFemale
        $0.appearance.detail = SkinDetail.matching(.averageFemale)
        $0.outfit = .casual
        $0.hair = .bob
    }
    var expression: FacialExpression = .neutral
    var speed: Float = 0
    var talking = false
    var crowd = 0
    var revision = 0
    var building = false
    var lastBuildMS = 0
    var stats = ""

    func rebuild() { revision += 1 }
}
