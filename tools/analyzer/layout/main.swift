import Darwin
// Isolated value-layout counterexperiment derived from frozen Swift scanner.
import Foundation

// Standalone generated-fixture tool. No AppKit, file-body reads, or mutation API.
enum Failure: Error { case invalid(String) }
let fields = ["data_logical", "all_logical", "data_allocated", "all_allocated"]
struct Observation {
  var name = Data()
  var masks = [UInt32](repeating: 0, count: 5)
  var dev: UInt64?
  var ino: UInt64?
  var links: UInt64?
  var flags: UInt32?
  var type: UInt32?
  var mount: UInt32?
  var error: UInt32 = 0
  var values = CoreMetrics()
  var kind: String {
    switch type {
    case 1: return "regular"
    case 2: return "directory"
    case 5: return "symlink"
    case nil, 0: return "unknown"
    default: return "other"
    }
  }
}
struct Cursor {
  let bytes: Data
  var offset: Int
  let end: Int
  mutating func read<T: FixedWidthInteger>(_ t: T.Type) throws -> T {
    guard offset >= 0, offset <= end, MemoryLayout<T>.size <= end - offset else {
      throw Failure.invalid("truncated_field")
    }
    let v = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    offset += MemoryLayout<T>.size
    return T(littleEndian: v)
  }
}
func parse(_ bytes: Data, count: Int, bulk: Bool) throws -> [Observation] {
  guard count >= 0, count <= 220_000 else { throw Failure.invalid("record_count") }
  var result: [Observation] = []
  var start = 0
  for _ in 0..<count {
    guard !bulk || start % 8 == 0 else { throw Failure.invalid("record_alignment") }
    var head = Cursor(bytes: bytes, offset: start, end: bytes.count)
    let length = Int(try head.read(UInt32.self))
    guard length >= 24, length <= bytes.count - start, !bulk || length % 8 == 0 else {
      throw Failure.invalid("record_length")
    }
    var c = Cursor(bytes: bytes, offset: start + 4, end: start + length)
    var o = Observation()
    for i in 0..<5 { o.masks[i] = try c.read(UInt32.self) }
    let allowed = [b06_common_mask(), UInt32(0), b06_directory_mask(), b06_file_mask(), UInt32(0)]
    guard zip(o.masks, allowed).allSatisfy({ $0 & ~$1 == 0 }), o.masks[0] & 0x8000_0000 != 0 else {
      throw Failure.invalid("unexpected_mask")
    }
    let common = o.masks[0]
    let directory = o.masks[2]
    let file = o.masks[3]
    if common & 0x2000_0000 != 0 {
      o.error = try c.read(UInt32.self)
      guard o.error <= UInt32(Int32.max) else { throw Failure.invalid("invalid_entry_errno") }
    }
    var nameStart: Int?
    var nameLength = 0
    if common & 1 != 0 {
      let reference = c.offset
      let displacement = try c.read(Int32.self)
      nameLength = Int(try c.read(UInt32.self))
      let (n, overflow) = reference.addingReportingOverflow(Int(displacement))
      guard !overflow, nameLength >= 2, n >= start + 24, n <= c.end, nameLength <= c.end - n else {
        throw Failure.invalid("name_range")
      }
      nameStart = n
    }
    if common & 2 != 0 { o.dev = UInt64(try c.read(UInt32.self)) }
    if common & 8 != 0 {
      o.type = try c.read(UInt32.self)
      guard o.type! <= 10 else { throw Failure.invalid("unknown_vnode_type") }
    }
    if common & 0x40000 != 0 { o.flags = try c.read(UInt32.self) }
    if common & 0x0200_0000 != 0 { o.ino = try c.read(UInt64.self) }
    if directory & 1 != 0 { o.links = UInt64(try c.read(UInt32.self)) }
    if directory & 4 != 0 { o.mount = try c.read(UInt32.self) }
    if file & 1 != 0 { o.links = UInt64(try c.read(UInt32.self)) }
    for (bit, i) in [(UInt32(2), 1), (4, 3), (0x200, 0), (0x400, 2)] {
      if file & bit != 0 {
        let v = try c.read(Int64.self)
        guard v >= 0 else { throw Failure.invalid("negative_size") }
        o.values[i] = UInt64(v)
      }
    }
    if let n = nameStart {
      guard n >= c.offset, bytes[n + nameLength - 1] == 0 else {
        throw Failure.invalid("name_overlap_or_terminator")
      }
      o.name = bytes.subdata(in: n..<(n + nameLength - 1))
      guard !o.name.contains(0), !o.name.contains(47), o.name != Data(".".utf8),
        o.name != Data("..".utf8)
      else { throw Failure.invalid("invalid_component") }
    } else if o.error == 0 {
      throw Failure.invalid("missing_name")
    }
    result.append(o)
    start += length
  }
  return result
}
func number(_ v: UInt64?) -> Any { v.map { String($0) } ?? NSNull() }
func maskObject(_ m: [UInt32]) -> [String: String] {
  Dictionary(
    uniqueKeysWithValues: zip(
      ["common", "volume", "directory", "file", "fork"], m.map(String.init)))
}
func observationJSON(_ o: Observation, path: Data, parent: Data) -> [String: Any] {
  var d: [String: Any] = [
    "relative_b64": path.base64EncodedString(), "parent_b64": parent.base64EncodedString(),
    "name_b64": o.name.base64EncodedString(), "type": o.kind, "dev": number(o.dev),
    "ino": number(o.ino), "nlink": number(o.links), "flags": number(o.flags.map(UInt64.init)),
    "returned": maskObject(o.masks), "errno": o.error,
  ]
  for i in 0..<4 {
    d[fields[i]] =
      o.error != 0
      ? ["state": "error"]
      : o.values[i].map { ["state": "returned", "value": String($0)] } ?? ["state": "not_returned"]
  }
  return d
}
// Digest format is deliberately language-independent; session/lane/traversal order excluded.
func canonical(_ o: Observation, _ path: Data) -> Data {
  var components: [String] = [
    "b06-record-v1", path.base64EncodedString(), o.name.base64EncodedString(), o.kind,
  ]
  components.append(o.dev.map { String($0) } ?? "-")
  components.append(o.ino.map { String($0) } ?? "-")
  components.append(o.links.map { String($0) } ?? "-")
  components.append(o.flags.map { String($0) } ?? "-")
  components.append(o.masks.map { String($0) }.joined(separator: ","))
  components.append(String(o.error))
  components.append(o.values.map { $0.map { String($0) } ?? "-" }.joined(separator: ","))
  return Data((components.joined(separator: "\n") + "\n").utf8)
}
struct Digest {
  var xor = [UInt8](repeating: 0, count: 32), sum = [UInt8](repeating: 0, count: 32)
  mutating func add(_ data: Data) {
    var h = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { p in b06_sha256(p.baseAddress, p.count, &h) }
    var carry: UInt16 = 0
    for i in (0..<32).reversed() {
      xor[i] ^= h[i]
      let s = UInt16(sum[i]) + UInt16(h[i]) + carry
      sum[i] = UInt8(truncatingIfNeeded: s)
      carry = s >> 8
    }
  }
  func hex(_ a: [UInt8]) -> String { a.map { String(format: "%02x", $0) }.joined() }
}
struct Options {
  var lane = "", root = "", session = ""
  var dev: UInt64 = 0, ino: UInt64 = 0
  var cancelAfter: UInt64?
  var summaryOnly = false
  var maximumDepth = 64
  var maximumQueue = 4096
  init(_ args: [String]) throws {
    var i = 0
    while i < args.count {
      let k = args[i]
      i += 1
      if k == "--summary-only" {
        summaryOnly = true
        continue
      }
      guard i < args.count else { throw Failure.invalid("missing_argument") }
      let v = args[i]
      i += 1
      switch k {
      case "--lane": lane = v
      case "--root": root = v
      case "--session": session = v
      case "--expected-dev":
        guard let n = UInt64(v) else { throw Failure.invalid("dev") }
        dev = n
      case "--expected-ino":
        guard let n = UInt64(v) else { throw Failure.invalid("ino") }
        ino = n
      case "--cancel-after":
        guard let n = UInt64(v) else { throw Failure.invalid("cancel") }
        cancelAfter = n
      case "--maximum-depth":
        guard let n = Int(v), n >= 0, n <= 64 else { throw Failure.invalid("depth") }
        maximumDepth = n
      case "--maximum-queue":
        guard let n = Int(v), n > 0, n <= 4096 else { throw Failure.invalid("queue") }
        maximumQueue = n
      default: throw Failure.invalid("unknown_argument")
      }
    }
    guard ["foundation", "bulk"].contains(lane), !session.isEmpty, session.utf8.count <= 128,
      dev > 0, ino > 0
    else { throw Failure.invalid("required_arguments") }
    let base = FileManager.default.currentDirectoryPath + "/.build/b06-analyzer/"
    guard root.hasPrefix(base), root.utf8.count <= 4096 else {
      throw Failure.invalid("root_admission")
    }
    let tail = String(root.dropFirst(base.count)).split(
      separator: "/", omittingEmptySubsequences: false)
    guard tail.count == 3, tail[1] == "fixtures",
      tail.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw Failure.invalid("root_admission") }
  }
}
final class Scanner {
  struct ObjectObservation {
    let values: CoreMetrics
    let links: UInt64?
    var edges: UInt64
  }
  let options: Options
  var entries: UInt64 = 0
  var counts = [String: UInt64]()
  var objects = [ObjectID: ObjectObservation]()
  var directories = Set<ObjectID>()
  var unknownObjectIdentity = false
  var totals = MetricTotals(), objectTotals = MetricTotals(), missing = MetricTotals()
  var digest = Digest()
  var errors: UInt64 = 0, issued = 0, calls: UInt64 = 0, bulkCalls: UInt64 = 0,
    nextCalls: UInt64 = 0, peakQueue = 0, peakFDs = 0
  var complete = true, reason = "complete", outputFailed = false
  var rootIdentity = B06Identity()
  var rootFD: Int32 = -1
  let start = DispatchTime.now().uptimeNanoseconds
  var startup = B06Resources()
  var resourceSupport = false
  init(_ options: Options) {
    self.options = options
    resourceSupport = b06_resources(&startup) == 0
  }
  func emit(_ kind: String, _ values: [String: Any]) {
    guard !outputFailed else { return }
    var d = values
    d["kind"] = kind
    d["schema"] = 1
    d["session"] = options.session
    if kind == "entry" || kind == "progress", b06_cancelled() != 0 {
      complete = false
      reason = "cancelled"
      return
    }
    do {
      var b = try JSONSerialization.data(
        withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])
      b.append(10)
      guard b.count <= 64 * 1024 else { throw Failure.invalid("output_record_limit") }
      try b.withUnsafeBytes { p in
        var offset = 0
        let begin = DispatchTime.now().uptimeNanoseconds
        while offset < p.count {
          let n = Darwin.write(STDOUT_FILENO, p.baseAddress!.advanced(by: offset), p.count - offset)
          if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
              guard DispatchTime.now().uptimeNanoseconds - begin < 5_000_000_000,
                b06_cancelled() == 0
              else { throw Failure.invalid("output_stalled") }
              var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
              _ = poll(&descriptor, 1, 20)
              continue
            }
            throw Failure.invalid("output_closed")
          }
          offset += n
        }
      }
    } catch {
      outputFailed = true
      complete = false
      reason = "output_closed"
    }
  }
  func issue(_ code: String, _ error: Int32 = 0) {
    errors += 1
    complete = false
    if reason == "complete" { reason = code }
    if issued < 100 {
      issued += 1
      emit("issue", ["code": code, "errno": error])
    }
  }
  func add(_ value: UInt64, to array: inout MetricTotals, at i: Int) throws {
    let (n, o) = array[i].addingReportingOverflow(value)
    guard !o else { throw Failure.invalid("overflow") }
    array[i] = n
  }
  func accept(_ o: Observation, _ parent: Data) throws {
    guard entries < 220_000 else { throw Failure.invalid("entry_limit") }
    guard !o.name.isEmpty else {
      issue("metadata_error", Int32(o.error))
      return
    }
    var path = parent
    if !path.isEmpty { path.append(47) }
    path.append(o.name)
    guard path.count <= 8192 else { throw Failure.invalid("path_limit") }
    entries += 1
    counts[o.kind, default: 0] += 1
    digest.add(canonical(o, path))
    if o.error != 0 {
      issue(o.error == UInt32(EDEADLK) ? "materialization_denied" : "entry_error", Int32(o.error))
    }
    if o.dev == nil || o.ino == nil || o.type == nil || o.type == 0 || o.flags == nil
      || o.links == nil
    {
      issue("missing_identity")
    }
    if o.kind == "regular" {
      let key = o.dev.flatMap { dev in o.ino.map { ObjectID(device: dev, inode: $0) } }
      var fresh = false
      if let key {
        if var previous = objects[key] {
          previous.edges += 1
          if previous.values != o.values || previous.links != o.links
            || previous.links.map({ previous.edges > $0 }) == true
          {
            issue("object_changed")
          }
          objects[key] = previous
        } else {
          objects[key] = ObjectObservation(values: o.values, links: o.links, edges: 1)
          fresh = true
        }
      } else {
        unknownObjectIdentity = true
      }
      for i in 0..<4 {
        if let v = o.values[i], o.error == 0 {
          try add(v, to: &totals, at: i)
          if fresh { try add(v, to: &objectTotals, at: i) }
        } else {
          missing[i] += 1
          complete = false
          if reason == "complete" { reason = "missing_fields" }
        }
      }
    }
    if !options.summaryOnly { emit("entry", observationJSON(o, path: path, parent: parent)) }
    if entries == 1 {
      emit(
        "progress",
        ["entries": "1", "elapsed_ns": String(DispatchTime.now().uptimeNanoseconds - start)])
    }
  }
  func identity(_ fd: Int32) throws -> B06Identity {
    var i = B06Identity()
    calls += 1
    guard b06_identity(fd, &i) == 0 else { throw Failure.invalid("identity_failed") }
    return i
  }
  func guarded(_ i: B06Identity, _ expected: B06Identity? = nil) -> Bool {
    i.local != 0 && i.dev == rootIdentity.dev && i.fsid0 == rootIdentity.fsid0
      && i.fsid1 == rootIdentity.fsid1 && i.flags & (0x0080_0000 | 0x4000_0000) == 0
      && (expected == nil || (i.dev == expected!.dev && i.ino == expected!.ino))
  }
  func stopped() -> Bool {
    if outputFailed { return true }
    if b06_cancelled() != 0 {
      complete = false
      reason = "cancelled"
      return true
    }
    if let n = options.cancelAfter, entries >= n {
      complete = false
      reason = "cancelled"
      return true
    }
    return false
  }
  struct Pending {
    let path: Data
    let dev: UInt64
    let ino: UInt64
    let depth: Int
  }
  func open(_ pending: Pending) throws -> Int32 {
    let relative = pending.path.isEmpty ? Data(".".utf8) : pending.path
    let fd = relative.withUnsafeBytes { p -> Int32 in
      var b = Array(p.bindMemory(to: UInt8.self))
      b.append(0)
      return b.withUnsafeBytes {
        b06_open_directory(rootFD, $0.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
    }
    guard fd >= 0 else { throw Failure.invalid("open_directory_failed") }
    do {
      let i = try identity(fd)
      guard guarded(i), i.dev == pending.dev, i.ino == pending.ino else {
        throw Failure.invalid("directory_changed")
      }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }
  func scan() throws {
    guard b06_set_utility_qos() == 0 else { throw Failure.invalid("worker_qos") }
    let old = b06_policy_get()
    guard old >= 0 else { throw Failure.invalid("materialization_policy") }
    defer {
      if b06_policy_restore(old) != 0 || b06_policy_get() != old {
        issue("materialization_restore")
      }
    }
    guard b06_policy_off() == 0, b06_policy_get() == 1 else {
      throw Failure.invalid("materialization_policy")
    }
    rootFD = options.root.withCString { b06_open_root($0) }
    guard rootFD >= 0 else { throw Failure.invalid("root_open") }
    defer {
      close(rootFD)
      rootFD = -1
    }
    rootIdentity = try identity(rootFD)
    guard rootIdentity.dev == options.dev, rootIdentity.ino == options.ino, guarded(rootIdentity)
    else { throw Failure.invalid("root_identity_or_boundary") }
    emit(
      "header",
      [
        "lane": options.lane, "materialization_policy": "off", "workers": 1,
        "worker_qos": "utility", "common_mask": String(b06_common_mask()),
        "directory_mask": String(b06_directory_mask()), "file_mask": String(b06_file_mask()),
        "profile": "core-v1",
        "scope_contract": options.lane == "foundation"
          ? "immutable-reference" : "descriptor-anchored",
      ])
    var queue = [Pending(path: Data(), dev: options.dev, ino: options.ino, depth: 0)]
    var head = 0
    while head < queue.count && !stopped() {
      let pending = queue[head]
      head += 1
      if head > 1024 {
        queue.removeFirst(head)
        head = 0
      }
      let fd: Int32
      do { fd = try open(pending) } catch {
        issue("directory_open", errno)
        continue
      }
      peakFDs = max(peakFDs, 2)
      defer { close(fd) }
      let before = try identity(fd)
      func receive(_ o: Observation) throws {
        if stopped() { return }
        try accept(o, pending.path)
        if o.kind == "directory", o.error == 0 {
          guard o.mount == 0, let dev = o.dev, dev == rootIdentity.dev, let ino = o.ino,
            let flags = o.flags, flags & (0x0080_0000 | 0x4000_0000) == 0
          else {
            issue("boundary_excluded")
            return
          }
          guard pending.depth < options.maximumDepth else {
            issue("depth_limit")
            return
          }
          guard directories.insert(ObjectID(device: dev, inode: ino)).inserted else {
            issue("duplicate_directory")
            return
          }
          guard queue.count - head < options.maximumQueue else {
            throw Failure.invalid("queue_limit")
          }
          var path = pending.path
          if !path.isEmpty { path.append(47) }
          path.append(o.name)
          queue.append(Pending(path: path, dev: dev, ino: ino, depth: pending.depth + 1))
          peakQueue = max(peakQueue, queue.count - head)
        }
      }
      if options.lane == "bulk" {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while !stopped() {
          bulkCalls += 1
          calls += 1
          let n = buffer.withUnsafeMutableBytes { b06_bulk(fd, $0.baseAddress, $0.count) }
          if n < 0 {
            issue(errno == EDEADLK ? "materialization_denied" : "bulk_error", errno)
            break
          }
          if n == 0 { break }
          for o in try parse(Data(buffer), count: Int(n), bulk: true) {
            try receive(o)
            if stopped() { break }
          }
        }
      } else {
        // Foundation cannot enumerate a /dev/fd directory on macOS. Owner accepted
        // this real-path lane only as an immutable generated-fixture reference.
        // Its internal path resolution cannot qualify concurrent replacement safety.
        var absolute = Data(options.root.utf8)
        if !pending.path.isEmpty {
          absolute.append(47)
          absolute.append(pending.path)
        }
        absolute.append(0)
        let url = absolute.withUnsafeBytes {
          URL(
            fileURLWithFileSystemRepresentation: $0.baseAddress!.assumingMemoryBound(
              to: CChar.self), isDirectory: true, relativeTo: nil)
        }
        guard
          let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
              .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ], options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
              self.issue("foundation_error", Int32((error as NSError).code))
              return false
            })
        else {
          issue("foundation_enumerator")
          continue
        }
        while !stopped() {
          nextCalls += 1
          let next: URL? = autoreleasepool { e.nextObject() as? URL }
          guard let child = next else { break }
          let bytes = child.withUnsafeFileSystemRepresentation { p -> Data in
            guard let p else { return Data() }
            return Data(bytes: p, count: strlen(p))
          }
          guard let slash = bytes.lastIndex(of: 47), slash + 1 < bytes.count else {
            throw Failure.invalid("foundation_name")
          }
          let name = bytes.subdata(in: (slash + 1)..<bytes.count)
          var buffer = [UInt8](repeating: 0, count: 8192)
          var component = Array(name)
          component.append(0)
          calls += 1
          let status = component.withUnsafeBytes { p in
            buffer.withUnsafeMutableBytes {
              b06_metadata(
                fd, p.baseAddress!.assumingMemoryBound(to: CChar.self), $0.baseAddress, $0.count)
            }
          }
          if status != 0 {
            issue(errno == EDEADLK ? "materialization_denied" : "metadata_error", errno)
            continue
          }
          var o = try parse(Data(buffer), count: 1, bulk: false)[0]
          // NAME queried on /dev/fd anchored metadata may canonicalize; enforce exact byte parity.
          guard o.name == name else { throw Failure.invalid("foundation_lossy_name") }
          o.name = name
          try receive(o)
        }
      }
      let after = try identity(fd)
      if before.dev != after.dev || before.ino != after.ino || before.mtime_sec != after.mtime_sec
        || before.mtime_nsec != after.mtime_nsec || before.ctime_sec != after.ctime_sec
        || before.ctime_nsec != after.ctime_nsec
      {
        issue("directory_changed")
      }
      guard guarded(try identity(rootFD)) else { throw Failure.invalid("root_changed") }
      // Re-open the admitted pathname to detect a moved/replaced root, without trusting canonicalization.
      let check = options.root.withCString { b06_open_root($0) }
      if check < 0 { throw Failure.invalid("root_replaced") }
      defer { close(check) }
      peakFDs = max(peakFDs, 3)
      let current = try identity(check)
      guard current.dev == options.dev, current.ino == options.ino else {
        throw Failure.invalid("root_replaced")
      }
    }
  }
  func finish() {
    var final = B06Resources()
    let resources = resourceSupport && b06_resources(&final) == 0
    var summary: [String: Any] = [
      "complete": complete, "reason": reason, "entries": String(entries),
      "regular_entries": String(counts["regular", default: 0]),
      "directory_entries": String(counts["directory", default: 0]),
      "symlink_entries": String(counts["symlink", default: 0]),
      "other_entries": String(counts["other", default: 0] + counts["unknown", default: 0]),
      "objects": String(objects.count),
      "entry_totals": Dictionary(uniqueKeysWithValues: zip(fields, totals.map(String.init))),
      "object_totals": Dictionary(uniqueKeysWithValues: zip(fields, objectTotals.map(String.init))),
      "missing_fields": Dictionary(uniqueKeysWithValues: zip(fields, missing.map(String.init))),
      "errors": String(errors), "issues_emitted": String(issued), "metadata_calls": String(calls),
      "bulk_calls": String(bulkCalls), "foundation_next_calls": String(nextCalls),
      "peak_queued_dirs": String(peakQueue), "peak_owned_fds": String(peakFDs),
      "elapsed_ns": String(DispatchTime.now().uptimeNanoseconds - start),
      "digest_xor": digest.hex(digest.xor), "digest_sum": digest.hex(digest.sum),
      "digest_count": String(entries),
    ]
    summary["object_accounting_state"] =
      unknownObjectIdentity ? "unknown" : (complete ? "returned" : "partial")
    summary["outside_link_objects"] = String(
      objects.values.filter { o in o.links.map { $0 > o.edges } ?? false }.count)
    summary["resource_metrics_state"] = resources ? "returned" : "error"
    if resources {
      summary["startup_current_rss"] = String(startup.current_rss)
      summary["peak_rss"] = String(final.peak_rss)
      summary["incremental_peak_rss"] = String(
        final.peak_rss > startup.current_rss ? final.peak_rss - startup.current_rss : 0)
      summary["post_drain_rss"] = String(final.current_rss)
      summary["user_ns"] = String(final.user_ns - startup.user_ns)
      summary["system_ns"] = String(final.system_ns - startup.system_ns)
    }
    emit("summary", summary)
  }
}
func selfTest() throws {
  func u<T: FixedWidthInteger>(_ n: T, _ b: inout Data) {
    var v = n.littleEndian
    withUnsafeBytes(of: &v) { b.append(contentsOf: $0) }
  }
  var b = Data()
  u(UInt32(48), &b)
  for x: UInt32 in [0xA000_0001, 0, 0, 0, 0] { u(x, &b) }
  u(UInt32(0), &b)
  u(Int32(8), &b)
  u(UInt32(2), &b)
  b.append(contentsOf: [97, 0])
  b.append(Data(repeating: 0, count: 10))
  let o = try parse(b, count: 1, bulk: true)[0]
  guard o.name == Data([97]), o.values.allSatisfy({ $0 == nil }) else {
    throw Failure.invalid("selftest_supported_zero")
  }
  var error = b
  error.replaceSubrange(24..<28, with: [UInt8(EACCES), 0, 0, 0])
  guard try parse(error, count: 1, bulk: true)[0].error == UInt32(EACCES) else {
    throw Failure.invalid("selftest_error")
  }
  var bads = [Data(b.prefix(20))]
  var bad = b
  bad[0] = 47
  bads.append(bad)
  bad = b
  bad[28] = 255
  bad[29] = 255
  bad[30] = 255
  bad[31] = 127
  bads.append(bad)
  bad = b
  bad[37] = 1
  bads.append(bad)
  for bad in bads {
    do {
      _ = try parse(bad, count: 1, bulk: true)
      throw Failure.invalid("selftest_accepted_bad")
    } catch Failure.invalid(let s) where s != "selftest_accepted_bad" {}
  }
  var aggregate = MetricTotals(dataLogical: UInt64.max)
  let scanner = Scanner(
    try Options([
      "--lane", "bulk", "--root",
      FileManager.default.currentDirectoryPath + "/.build/b06-analyzer/selftest/fixtures/test",
      "--expected-dev", "1", "--expected-ino", "1", "--session", "selftest",
    ]))
  do {
    try scanner.add(1, to: &aggregate, at: 0)
    throw Failure.invalid("selftest_missed_overflow")
  } catch Failure.invalid(let code) where code == "overflow" {}
  var zero = Data()
  u(UInt32(48), &zero)
  for x: UInt32 in [0x8000_0001, 0, 0, 0x200, 0] { u(x, &zero) }
  u(Int32(16), &zero)
  u(UInt32(2), &zero)
  u(Int64(0), &zero)
  zero.append(contentsOf: [97, 0])
  zero.append(Data(repeating: 0, count: 6))
  guard try parse(zero, count: 1, bulk: true)[0].values[0] == 0 else {
    throw Failure.invalid("selftest_returned_zero")
  }
  var raw = b
  raw[36] = 255
  guard try parse(raw, count: 1, bulk: true)[0].name == Data([255]) else {
    throw Failure.invalid("selftest_raw_name")
  }
  var negatives = [Data]()
  bad = zero
  bad.replaceSubrange(32..<40, with: Data(repeating: 255, count: 8))
  negatives.append(bad)
  bad = b
  bad[8] = 1
  negatives.append(bad)  // unrequested volume bit
  bad = b
  bad[28] = 0
  negatives.append(bad)  // name overlaps fixed fields
  bad = b
  bad[36] = 47
  negatives.append(bad)  // slash component
  bad = b
  bad[36] = 46
  negatives.append(bad)  // dot component
  bad = b
  bad[7] = 0
  negatives.append(bad)  // missing returned-attrs bit
  var vnode = Data()
  u(UInt32(48), &vnode)
  for x: UInt32 in [0x8000_0009, 0, 0, 0, 0] { u(x, &vnode) }
  u(Int32(12), &vnode)
  u(UInt32(2), &vnode)
  u(UInt32(999), &vnode)
  vnode.append(contentsOf: [97, 0])
  vnode.append(Data(repeating: 0, count: 10))
  negatives.append(vnode)
  bad = b
  bad.replaceSubrange(24..<28, with: Data(repeating: 255, count: 4))
  negatives.append(bad)
  for bad in negatives {
    do {
      _ = try parse(bad, count: 1, bulk: true)
      throw Failure.invalid("selftest_accepted_bad")
    } catch Failure.invalid(let s) where s != "selftest_accepted_bad" {}
  }
  print("{\"kind\":\"selftest\",\"schema\":1,\"passed\":17}")
}
signal(SIGPIPE, SIG_IGN)
b06_install_cancellation()
let outputFlags = fcntl(STDOUT_FILENO, F_GETFL)
guard outputFlags >= 0, fcntl(STDOUT_FILENO, F_SETFL, outputFlags | O_NONBLOCK) == 0 else {
  exit(74)
}
if CommandLine.arguments.dropFirst() == ["--layout-self-test"] {
  do { try layoutSelfTest() } catch {
    fputs("layout_selftest_failed\n", stderr)
    exit(2)
  }
} else if CommandLine.arguments.dropFirst() == ["--self-test"] {
  do { try selfTest() } catch {
    fputs("selftest_failed\n", stderr)
    exit(2)
  }
} else {
  do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    let scanner = Scanner(options)
    let done = DispatchSemaphore(value: 0)
    let worker = Thread {
      defer { done.signal() }
      do { try scanner.scan() } catch Failure.invalid(let code) { scanner.issue(code, errno) } catch
      { scanner.issue("scan_failed", errno) }
      scanner.finish()
    }
    worker.qualityOfService = .utility
    worker.start()
    done.wait()
    exit(scanner.complete ? 0 : 2)
  } catch {
    fputs("invalid_admission_or_arguments\n", stderr)
    exit(64)
  }
}
