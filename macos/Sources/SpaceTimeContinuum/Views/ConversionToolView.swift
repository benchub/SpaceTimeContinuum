import STCCore
import SwiftUI

struct ConversionToolView: View {
    @ObservedObject var model: AppModel

    @State private var secondsText = ""
    @State private var metersText = ""
    @State private var timeResult = ""
    @State private var distanceResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            row(title: "Time (seconds)", text: $secondsText, result: timeResult, kind: .time)
            row(title: "Distance (meters)", text: $metersText, result: distanceResult, kind: .space)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 220)
    }

    private func row(title: String, text: Binding<String>, result: String, kind: MeasureKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                TextField("0", text: text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { convert(text.wrappedValue, kind) }
                Button("Convert") { convert(text.wrappedValue, kind) }
            }
            Text(result.isEmpty ? " " : result)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func convert(_ input: String, _ kind: MeasureKind) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let result: String
        if let value = Double(trimmed), value.isFinite, value >= 0 {
            result = model.silly(value, kind)
        } else {
            result = "Enter a non-negative number."
        }
        if kind == .time { timeResult = result } else { distanceResult = result }
    }
}
