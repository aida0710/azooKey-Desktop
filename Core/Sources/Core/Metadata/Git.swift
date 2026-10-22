public struct PackageMetadata {
    public static var gitTag: String? {
        #if AZOOKEY_GIT_INFO_UNAVAILABLE
        nil
        #else
        gitTagFromPlugin
        #endif
    }
    public static var gitCommit: String? {
        #if AZOOKEY_GIT_INFO_UNAVAILABLE
        nil
        #else
        gitCommitFromPlugin
        #endif
    }
}
