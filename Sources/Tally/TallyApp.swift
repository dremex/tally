import SwiftUI

@main
struct TallyApp: App {
    @StateObject private var vm = NetworkViewModel()
    @State private var coordinator: SamplingCoordinator?

    var body: some Scene {
        MenuBarExtra {
            DetailView()
                .environmentObject(vm)
                .frame(width: 420, height: 540)
        } label: {
            // Rendered as a coloured NSImage (down=blue, up=aqua); the menu bar flattens plain
            // SwiftUI Text to monochrome, so we draw it ourselves. Re-renders when rates change.
            Image(nsImage: menuBarImage)
                .onAppear {
                    if coordinator == nil {
                        let c = SamplingCoordinator(viewModel: vm)
                        c.start()
                        coordinator = c
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }

    /// Reading the published rates here makes SwiftUI re-render the label image each time they change.
    private var menuBarImage: NSImage {
        _ = vm.rxRate
        _ = vm.txRate
        return vm.renderMenuBarImage()
    }
}
