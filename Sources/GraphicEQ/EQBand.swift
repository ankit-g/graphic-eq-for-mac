import Foundation

struct EQBandDefinition {
    let frequency: Double
    let label: String
}

enum EQBands {
    static let definitions: [EQBandDefinition] = [
        EQBandDefinition(frequency: 32, label: "32"),
        EQBandDefinition(frequency: 64, label: "64"),
        EQBandDefinition(frequency: 125, label: "125"),
        EQBandDefinition(frequency: 250, label: "250"),
        EQBandDefinition(frequency: 500, label: "500"),
        EQBandDefinition(frequency: 1000, label: "1k"),
        EQBandDefinition(frequency: 2000, label: "2k"),
        EQBandDefinition(frequency: 4000, label: "4k"),
        EQBandDefinition(frequency: 8000, label: "8k"),
        EQBandDefinition(frequency: 16000, label: "16k"),
    ]

    static let count = definitions.count
    static let gainRange: ClosedRange<Float> = -12...12
    static let bandwidth: Float = 0.8
}
