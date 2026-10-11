import SwiftUI

/// A compact date button that presents a full calendar in a popover.
///
/// Use this control for individual dates as well as the start and end dates
/// of a custom range. Changes are written to `selection` immediately.
struct PopoverDatePicker: View {
    private let title: LocalizedStringKey
    @Binding private var selection: Date
    private let bounds: ClosedRange<Date>?

    @State private var isPresented = false

    init(
        _ title: LocalizedStringKey,
        selection: Binding<Date>,
        in bounds: ClosedRange<Date>? = nil
    ) {
        self.title = title
        _selection = selection
        self.bounds = bounds
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label {
                Text(selection, format: .dateTime.day().month(.abbreviated).year())
            } icon: {
                Image(systemName: "calendar")
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(
            Text(selection, format: .dateTime.day().month(.wide).year())
        )
        .popover(isPresented: $isPresented) {
            PopoverDatePickerCalendar(
                title: title,
                selection: $selection,
                bounds: bounds
            )
        }
    }
}

private struct PopoverDatePickerCalendar: View {
    @Environment(\.dismiss) private var dismiss

    let title: LocalizedStringKey
    @Binding var selection: Date
    let bounds: ClosedRange<Date>?

    var body: some View {
        VStack(spacing: 8) {
            calendar

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var calendar: some View {
        if let bounds {
            DatePicker(
                title,
                selection: $selection,
                in: bounds,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .focusEffectDisabled()
        } else {
            DatePicker(
                title,
                selection: $selection,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .focusEffectDisabled()
        }
    }
}
