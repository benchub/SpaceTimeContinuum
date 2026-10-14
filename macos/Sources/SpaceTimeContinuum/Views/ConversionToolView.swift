import STCCore
import SwiftUI

struct ConversionToolView: View {
    @ObservedObject var model: AppModel

    @State private var secondsText = ""
    @State private var metersText = ""
    @State private var timeResult = ""
    @State private var distanceResult = ""
    @FocusState private var focused: MeasureKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            row(title: "Time (seconds)", text: $secondsText, result: timeResult, kind: .time)
            row(title: "Distance (meters)", text: $metersText, result: distanceResult, kind: .space)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 220)
        .onAppear { focused = .time }
    }

    private func row(title: String, text: Binding<String>, result: String, kind: MeasureKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                TextField("0", text: text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: kind)
                    .onChange(of: text.wrappedValue) { _, new in
                        let clean = Self.sanitize(new)
                        if clean != new { text.wrappedValue = clean }
                    }
                    .onSubmit { convert(text.wrappedValue, kind) }
                Button("Convert") { convert(text.wrappedValue, kind) }
            }
            Text(result.isEmpty ? " " : result)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Digits and at most one period; a leading period gets a 0 in front.
    private static func sanitize(_ input: String) -> String {
        var out = ""
        var seenPeriod = false
        for ch in input {
            if ch.isASCII, ch.isNumber {
                out.append(ch)
            } else if ch == ".", !seenPeriod {
                seenPeriod = true
                if out.isEmpty { out = "0" }
                out.append(ch)
            }
        }
        return out
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
