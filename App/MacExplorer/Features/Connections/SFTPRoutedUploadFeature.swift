import Foundation

/// I is a separate, file-only composition. Qualification cannot change F's
/// read-only meaning or enable folder Upload through a saved connection.
@MainActor enum SFTPRoutedUploadFeature {
    #if DEBUG
    static var qualifying = false
    #endif
    static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.routedUpload)
    }
}

/// J composes the existing tree writer with the same verified two-role route.
/// No ordinary selection follows until its independent/native gates pass.
@MainActor enum SFTPRoutedFolderUploadFeature {
    #if DEBUG
    static var qualifying = false
    #endif
    static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.routedUpload)
            && AppFeatureAvailability.allows(.serverFolderUpload)
    }
}
