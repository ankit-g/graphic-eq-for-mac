import SwiftUI

struct EQSliderView: View {
    let label: String
    @Binding var gain: Float

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", gain))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(value: $gain, in: EQBands.gainRange, step: 0.5)
                .frame(width: 100)
                .rotationEffect(.degrees(-90), anchor: .center)
                .frame(width: 30, height: 100)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
