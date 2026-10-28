import SwiftUI
import AppKit

struct ReportValueRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(localizedMessage(title)).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(verbatim: value).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 6)
    }
}
