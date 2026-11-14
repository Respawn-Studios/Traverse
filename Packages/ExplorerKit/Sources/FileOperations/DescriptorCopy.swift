import Darwin
import Foundation

// Transient observations used only to validate an explicitly requested copy.
// No user-file metadata, contents, or symbolic-link targets are logged or persisted.
internal struct TreeNode: Equatable {
    let snapshot: EntrySnapshot
    let linkTarget: [UInt8]?
}

/// Internal fixture seam. Production always uses native copy without injection.
internal struct CopyFaultHooks: Sendable {
    var beforeNativeCopy: (@Sendable (_ sourceFD: Int32, _ destinationFD: Int32) throws -> Void)?
    var afterNativeCopy: (@Sendable (_ sourceFD: Int32, _ destinationFD: Int32) throws -> Void)?
    var afterSecurityReceipt: (@Sendable (_ sourceFD: Int32, _ destinationFD: Int32) throws -> Void)?
}

internal func copyNode(sourceParent: Int32, sourceName: String, destinationParent: Int32,
                       destinationName: String, relative: String, originalDevice: dev_t,
                       cancellation: OperationCancellation, observations: inout [String: TreeNode], depth: Int = 0) throws {
    var optional: [String: TreeNode]? = observations
    defer { observations = optional ?? [:] }
    try copyNodeImpl(sourceParent: sourceParent, sourceName: sourceName, destinationParent: destinationParent,
        destinationName: destinationName, relative: relative, originalDevice: originalDevice,
        cancellation: cancellation, observations: &optional, depth: depth, budget: TraversalBudget(), onDataProgress: nil, faults: CopyFaultHooks(), nativeProfile: .ordinary, completed: nil, securityReceipt: nil)
}

internal func copyVerifiedNode(sourceParent: Int32, sourceName: String, destinationParent: Int32,
                              destinationName: String, originalDevice: dev_t, cancellation: OperationCancellation,
                              onDataProgress: (@Sendable (Int64) -> Void)? = nil,
                              nativeProfile: NativeCopyProfile = .ordinary,
                              faults: CopyFaultHooks = CopyFaultHooks(),
                              completed: (@Sendable (String, EntrySnapshot) throws -> Void)? = nil,
                              securityReceipt: (@Sendable (NativeCopyReceipt) throws -> Void)? = nil) throws {
    var observations: [String: TreeNode]? = nil
    try copyNodeImpl(sourceParent: sourceParent, sourceName: sourceName, destinationParent: destinationParent,
        destinationName: destinationName, relative: "", originalDevice: originalDevice,
        cancellation: cancellation, observations: &observations, depth: 0, budget: TraversalBudget(), onDataProgress: onDataProgress, faults: faults, nativeProfile: nativeProfile, completed: completed, securityReceipt: securityReceipt)
}

private func copyNodeImpl(sourceParent: Int32, sourceName: String, destinationParent: Int32,
                         destinationName: String, relative: String, originalDevice: dev_t,
                         cancellation: OperationCancellation, observations: inout [String: TreeNode]?,
                         depth: Int, budget: TraversalBudget, onDataProgress: (@Sendable (Int64) -> Void)?,
                         faults: CopyFaultHooks, nativeProfile: NativeCopyProfile, completed: (@Sendable (String, EntrySnapshot) throws -> Void)?,
                         securityReceipt: (@Sendable (NativeCopyReceipt) throws -> Void)?) throws {
    try cancellation.check()
    let before = try EntrySnapshot(parent: sourceParent, name: sourceName)
    try budget.consume(before, depth: depth)
    cancellation.progress?.visit(relative: relative)
    guard before.device == originalDevice else { throw FileOperationFailure.unsupported }
    let type = before.type
    guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else { throw FileOperationFailure.unsupported }
    // O_SYMLINK opens the link itself; O_NOFOLLOW combined with it rejects links.
    if nativeProfile == .privateTextRevisionV1 { try preflightPrivateTextCopyEntry(parent: sourceParent, name: sourceName) }
    let flags = type == S_IFDIR ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        : type == S_IFLNK ? O_RDONLY | O_SYMLINK : O_RDONLY | O_NOFOLLOW
    let source = openat(sourceParent, sourceName, flags | O_NONBLOCK | O_CLOEXEC)
    guard source >= 0 else { throw copyPOSIXFailure() }
    defer { close(source) }
    guard try EntrySnapshot(fd: source) == before else { throw FileOperationFailure.sourceChanged }
    if nativeProfile == .privateTextRevisionV1 {
        try validatePrivateTextCopySource(source, destinationParent: destinationParent, depth: depth, relative: relative)
    }
    var target: [UInt8]?
    if type == S_IFLNK { target = try linkBytes(parent: sourceParent, name: sourceName) }
    if observations != nil { observations?[relative] = TreeNode(snapshot: before, linkTarget: target) }

    let destination: Int32
    if type == S_IFDIR {
        guard mkdirat(destinationParent, destinationName, 0o700) == 0 else { throw copyPOSIXFailure() }
        destination = openat(destinationParent, destinationName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    } else if let target {
        let terminated = target.map { CChar(bitPattern: $0) } + [0]
        let result = terminated.withUnsafeBufferPointer { symlinkat($0.baseAddress!, destinationParent, destinationName) }
        guard result == 0 else { throw copyPOSIXFailure() }
        destination = openat(destinationParent, destinationName, O_RDONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
    } else {
        destination = openat(destinationParent, destinationName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard destination >= 0 else { throw copyPOSIXFailure() }
    defer { close(destination) }
    let destinationCreated = try EntrySnapshot(fd: destination)
    guard destinationCreated.type == type else { throw FileOperationFailure.destinationChanged }

    if type == S_IFDIR {
        for child in try childNames(in: source, cancellation: cancellation, limit: budget.remaining) {
            let childRelative = relative.isEmpty ? child : relative + "/" + child
            try copyNodeImpl(sourceParent: source, sourceName: child, destinationParent: destination,
                         destinationName: child, relative: childRelative, originalDevice: originalDevice,
                         cancellation: cancellation, observations: &observations, depth: depth + 1, budget: budget, onDataProgress: onDataProgress, faults: faults, nativeProfile: nativeProfile, completed: completed, securityReceipt: securityReceipt)
        }
    }
    try cancellation.check()
    try faults.beforeNativeCopy?(source, destination)
    let sourceSecurity = try securityReceipt.map { _ in try CopySecurity.read(source) }
    let destinationSecurity = try securityReceipt.map { _ in try CopySecurity.read(destination) }
    try nativeCopy(from: source, to: destination, flags: UInt32(type == S_IFREG ? COPYFILE_ALL : COPYFILE_METADATA), cancellation: cancellation, logicalSize: type == S_IFREG ? before.size : 0, onDataProgress: onDataProgress)
    try preserveCopiedDocumentTracking(source: source, destination: destination)
    if nativeProfile == .privateTextRevisionV1 {
        try preservePrivateTextCopyBirth(source: source, destination: destination, created: destinationCreated)
    }
    try faults.afterNativeCopy?(source, destination)
    let afterSourceSecurity = try securityReceipt.map { _ in try CopySecurity.read(source) }
    let afterDestinationSecurity = try securityReceipt.map { _ in try CopySecurity.read(destination) }
    let destinationOwnership = try securityReceipt.map { _ in try CopyOwnership.read(destination) }
    cancellation.progress?.advance(items: 1)
    guard try EntrySnapshot(fd: source) == before,
          try EntrySnapshot(parent: sourceParent, name: sourceName) == before else { throw FileOperationFailure.sourceChanged }
    if type == S_IFREG {
        guard try EntrySnapshot(fd: destination).size == before.size else { throw FileOperationFailure.ioFailure }
    }
    let copied = try EntrySnapshot(fd: destination)
    guard try EntrySnapshot(parent: destinationParent, name: destinationName).sameObject(as: copied) else {
        throw FileOperationFailure.destinationChanged
    }
    // The exclusively created descriptor remains open through this receipt. Only a
    // fully completed copy can supply receipts for every node, including its root.
    if let securityReceipt, let sourceSecurity, let destinationSecurity, let afterSourceSecurity, let afterDestinationSecurity, let destinationOwnership {
        try securityReceipt(NativeCopyReceipt(relative: relative, source: before, destination: copied, destinationBeforeIdentity: destinationCreated, destinationOwnership: destinationOwnership,
            sourceBefore: sourceSecurity, destinationBefore: destinationSecurity,
            sourceAfter: afterSourceSecurity, destinationAfter: afterDestinationSecurity))
    }
    try faults.afterSecurityReceipt?(source, destination)
    try completed?(relative, copied)
}

internal func snapshotTree(parent: Int32, name: String, cancellation: OperationCancellation) throws -> [String: TreeNode] {
    var result: [String: TreeNode] = [:]
    let budget = TraversalBudget()
    let root = try EntrySnapshot(parent: parent, name: name)
    func visit(_ parent: Int32, _ name: String, _ relative: String, _ depth: Int) throws {
        try cancellation.check()
        let snapshot = try EntrySnapshot(parent: parent, name: name)
        try budget.consume(snapshot, depth: depth)
        guard snapshot.device == root.device else { throw FileOperationFailure.unsupported }
        let target = snapshot.type == S_IFLNK ? try linkBytes(parent: parent, name: name) : nil
        result[relative] = TreeNode(snapshot: snapshot, linkTarget: target)
        if snapshot.isDirectory {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw copyPOSIXFailure() }
            defer { close(fd) }
            guard try EntrySnapshot(fd: fd) == snapshot else { throw FileOperationFailure.sourceChanged }
            for child in try childNames(in: fd, cancellation: cancellation, limit: budget.remaining) {
                try visit(fd, child, relative.isEmpty ? child : relative + "/" + child, depth + 1)
            }
            guard try EntrySnapshot(fd: fd) == snapshot else { throw FileOperationFailure.sourceChanged }
        }
    }
    try visit(parent, name, "", 0)
    return result
}

internal func equivalentCopies(_ source: [String: TreeNode], _ destination: [String: TreeNode]) -> Bool {
    guard source.count == destination.count else { return false }
    return source.allSatisfy { key, original in
        guard let copied = destination[key], original.snapshot.type == copied.snapshot.type else { return false }
        if original.snapshot.type == S_IFREG && original.snapshot.size != copied.snapshot.size { return false }
        return original.linkTarget == copied.linkTarget
    }
}

internal func childNames(in fd: Int32, cancellation: OperationCancellation, limit: Int? = nil) throws -> [String] {
    let duplicated = dup(fd)
    guard duplicated >= 0 else { throw copyPOSIXFailure() }
    guard let directory = fdopendir(duplicated) else { close(duplicated); throw copyPOSIXFailure() }
    defer { closedir(directory) }
    // dup shares the directory offset; rewind before each independent traversal.
    rewinddir(directory)
    var names: [String] = []
    while true {
        try cancellation.check()
        errno = 0
        guard let entry = readdir(directory) else {
            guard errno == 0 else { throw copyPOSIXFailure() }
            break
        }
        let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
        }
        guard let name else { throw FileOperationFailure.unsupported }
        if name != "." && name != ".." {
            if let limit, names.count >= limit { throw FileOperationFailure.unsupported }
            names.append(name)
        }
    }
    return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

internal func linkBytes(parent: Int32, name: String) throws -> [UInt8] {
    var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let capacity = bytes.count
    let count = bytes.withUnsafeMutableBufferPointer { readlinkat(parent, name, $0.baseAddress!, capacity) }
    guard count >= 0 else { throw copyPOSIXFailure() }
    guard count < capacity else { throw FileOperationFailure.unsupported }
    return bytes.prefix(count).map { UInt8(bitPattern: $0) }
}

private final class CopyProgressContext {
    let cancellation: OperationCancellation
    let logicalSize: Int64
    var completed: Int64 = 0
    var firstError: Int32?
    let onDataProgress: (@Sendable (Int64) -> Void)?
    init(_ cancellation: OperationCancellation, size: Int64, onDataProgress: (@Sendable (Int64) -> Void)?) {
        self.cancellation = cancellation; logicalSize = size; self.onDataProgress = onDataProgress
    }
    func observe(_ count: Int64) {
        let next = min(logicalSize, max(completed, count))
        cancellation.progress?.advance(bytes: next - completed); completed = next
    }
}

private func nativeCopy(from source: Int32, to destination: Int32, flags: UInt32, cancellation: OperationCancellation, logicalSize: Int64, onDataProgress: (@Sendable (Int64) -> Void)?) throws {
    guard let state = copyfile_state_alloc() else { throw FileOperationFailure.ioFailure }
    defer { copyfile_state_free(state) }
    let context = CopyProgressContext(cancellation, size: logicalSize, onDataProgress: onDataProgress)
    let callback: copyfile_callback_t = { what, stage, state, _, _, context in
        let callbackErrno = errno
        defer { errno = callbackErrno }
        guard let context else { return COPYFILE_QUIT }
        let value = Unmanaged<CopyProgressContext>.fromOpaque(context).takeUnretainedValue()
        // copyfile(3) defines errno at COPYFILE_ERR. There is no public STATE_ERR.
        // Preserve it before progress observers/state queries can alter thread errno.
        if stage == COPYFILE_ERR, value.firstError == nil, callbackErrno != 0 { value.firstError = callbackErrno }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                value.observe(Int64(copied)); value.onDataProgress?(Int64(copied))
            }
        }
        return value.cancellation.isCancelled || stage == COPYFILE_ERR ? COPYFILE_QUIT : COPYFILE_CONTINUE
    }
    let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
    guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer) == 0,
          copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque()) == 0 else {
        throw FileOperationFailure.ioFailure
    }
    let result = fcopyfile(source, destination, state, flags)
    let failure = errno
    try validateNativeCopyResult(result: result, error: failure, callbackError: context.firstError, cancellation: cancellation)
    context.observe(logicalSize)
}

internal func validateNativeCopyResult(result: Int32, error: Int32, callbackError: Int32?, cancellation: OperationCancellation) throws {
    if result != 0 {
        // Prefer the native call's concrete final error. Some metadata callbacks
        // precede the library assigning its final error (notably quarantine).
        // Recover callback errno only when QUIT replaced it with cancellation.
        let cause = (error == ECANCELED || error == 0) ? (callbackError ?? error) : error
        if cause == ECANCELED || cause == 0 { try cancellation.check() }
        throw posixFailure(cause)
    }
    try cancellation.check()
}

private func copyPOSIXFailure(_ code: Int32 = errno) -> FileOperationFailure { posixFailure(code) }
