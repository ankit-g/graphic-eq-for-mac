import SwiftUI
import AppKit

struct StatusBarPopoverView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable EQ", isOn: $appState.isEnabled)
                .toggleStyle(.switch)

            Picker("Output Device", selection: outputDeviceBinding) {
                ForEach(appState.availableOutputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(EQBands.definitions.indices, id: \.self) { index in
                    EQSliderView(label: EQBands.definitions[index].label, gain: gainBinding(for: index))
                }
            }
            .padding(.vertical, 8)

            if let status = appState.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { appState.refreshAvailableDevices() }
    }

    private var outputDeviceBinding: Binding<String> {
        Binding(
            get: { appState.selectedOutputDeviceUID ?? "" },
            set: { appState.selectedOutputDeviceUID = $0 }
        )
    }

    private func gainBinding(for index: Int) -> Binding<Float> {
        Binding(
            get: { appState.bandGains[index] },
            set: { appState.bandGains[index] = $0 }
        )
    }
}
