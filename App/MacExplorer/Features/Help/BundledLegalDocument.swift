enum BundledLegalDocument: Sendable {
    case thirdParty, projectLicense

    var title: String {
        switch self {
        case .thirdParty: "Third-Party Software Notices"
        case .projectLicense: "GNU General Public License v3"
        }
    }
}
