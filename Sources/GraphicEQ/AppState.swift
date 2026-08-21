import Foundation
import Combine

final class AppState: ObservableObject {
    private enum Keys {
        static let bandGains = "bandGains"
        static let selectedOutputDeviceUID = "selectedOutputDeviceUID"
    }

    @Published var isEnabled: Bool = false
    @Published var bandGains: [Float]
    @Published var selectedOutputDeviceUID: String?
    @Published var availableOutputDevices: [AudioDeviceInfo] = []
    @Published var statusMessage: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: Keys.bandGains) as? [Float], saved.count == EQBands.count {
            self.bandGains = saved
        } else {
            self.bandGains = Array(repeating: 0, count: EQBands.count)
        }
        self.selectedOutputDeviceUID = defaults.string(forKey: Keys.selectedOutputDeviceUID)

        refreshAvailableDevices()

        $bandGains
            .dropFirst()
            .sink { gains in
                UserDefaults.standard.set(gains, forKey: Keys.bandGains)
            }
            .store(in: &cancellables)

        $selectedOutputDeviceUID
            .dropFirst()
            .sink { uid in
                UserDefaults.standard.set(uid, forKey: Keys.selectedOutputDeviceUID)
            }
            .store(in: &cancellables)
    }

    func refreshAvailableDevices() {
        let devices = AudioDeviceManager.outputCapableDevices()
        availableOutputDevices = devices
        if selectedOutputDeviceUID == nil || !devices.contains(where: { $0.uid == selectedOutputDeviceUID }) {
            selectedOutputDeviceUID = devices.first?.uid
        }
    }
}
