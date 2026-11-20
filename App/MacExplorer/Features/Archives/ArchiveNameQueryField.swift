import AppKit
import SwiftUI

/// ZIP and TAR share a native field with a stable focus identity. The owning
/// model still decides when to query; editing does not open archive members.
struct ArchiveNameQueryField: View {
    @Binding var text: String
    let global: Bool
    let onSubmit: () -> Void
    var fieldID = "archive-name-query"
    var placeholder: String?

    var body: some View {
        NativeQueryField(text: $text, identifier: fieldID,
            placeholder: placeholder ?? (global ? "Search archive names" : "Filter this folder")) { key in
            switch key {
            case .submit: onSubmit(); return true
            case .cancel: text = ""; onSubmit(); return true
            case .up, .down: return false
            }
        }
    }
}
