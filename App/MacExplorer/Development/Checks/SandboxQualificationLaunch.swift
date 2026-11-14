#if DEBUG
    /// A diagnostic artifact must not become an ordinary browser when a native
    /// inspection tool unexpectedly reopens it without its controlled arguments.
    /// Exact case/root/signature authority is still checked by the native packet.
    enum SandboxQualificationLaunch {
        static func permits(hasCaseMarker: Bool, arguments: [String]) -> Bool {
            guard hasCaseMarker else { return true }
            let checks = arguments.filter { $0.hasPrefix("--check-") }
            return arguments.contains("--verify-ui")
                && (checks == ["--check-sandbox-foundation"] || checks == ["--check-incoming-system"] || checks == ["--check-file-workflow-system"] || checks == ["--check-sftp-live-standalone"] || checks == ["--check-sftp-connect-standalone"] || checks == ["--check-sftp-lifetime-standalone"] || checks == ["--check-smb-selected-download"])
                && !arguments.contains { $0.hasPrefix("--show-") }
        }
    }
#endif
