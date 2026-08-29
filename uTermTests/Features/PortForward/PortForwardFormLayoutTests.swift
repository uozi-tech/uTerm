import AppKit
import SwiftUI
import XCTest
import UDesignKit
@testable import uTerm

@MainActor
final class PortForwardFormLayoutTests: XCTestCase {
    func testPortFieldsKeepUsableWidthBesideLongAddress() {
        let widths = FormFieldWidthStore()
        let view = PortForwardFormRowProbe(widths: widths)
            .frame(width: 406, height: 80)
            .background(UD.bg)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 406, height: 80)

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(widths.port, 104)
    }
}

@MainActor
private final class FormFieldWidthStore {
    var port: CGFloat = 0
}

private struct PortForwardFormRowProbe: View {
    @State private var host = "db.internal.example.com"
    @State private var port = ""

    let widths: FormFieldWidthStore

    var body: some View {
        FormRow {
            FormField(label: "地址", flex: 2) {
                UDTextField(placeholder: "127.0.0.1", text: $host, monospaced: true)
            }
            FormField(label: "端口", flex: 1) {
                UDTextField(placeholder: "端口", text: $port, monospaced: true)
                    .background(WidthReporter { widths.port = $0 })
            }
        }
    }
}

private struct WidthReporter: NSViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.reportWidth()
    }
}

@MainActor
private final class ReportingView: NSView {
    var onChange: (@MainActor (CGFloat) -> Void)?

    override func layout() {
        super.layout()
        reportWidth()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportWidth()
    }

    func reportWidth() {
        onChange?(bounds.width)
    }
}
