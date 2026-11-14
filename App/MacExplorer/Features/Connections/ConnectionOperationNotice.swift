/// A result belongs to its connection/directory, rather than the last network
/// refresh. Attention stays visible when a connection fails; a success never
/// hides a later disconnection. This value carries no operation authority.
struct ConnectionOperationNotice {
    let message: String
    let needsAttention: Bool
    let showsUploadHistory: Bool

    init(message: String, needsAttention: Bool, showsUploadHistory: Bool = true) {
        self.message = message; self.needsAttention = needsAttention; self.showsUploadHistory = showsUploadHistory
    }

    func footerMessage(isIdle: Bool, connectionHasProblem: Bool) -> String? {
        needsAttention || isIdle && !connectionHasProblem ? message : nil
    }
}
