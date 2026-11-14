import Foundation

/// Filesystem identity is a pair of integers. Its hash does not allocate a
/// decimal string or change the object-deduplication rule.
struct ObjectID: Hashable {
  let device: UInt64
  let inode: UInt64
}

/// Four inline values plus support bits preserve the original array's optional
/// semantics. A returned zero is distinct from an unavailable slot.
struct CoreMetrics: Equatable, MutableCollection, RandomAccessCollection {
  typealias Index = Int
  typealias Element = UInt64?

  private var dataLogical: UInt64 = 0
  private var allLogical: UInt64 = 0
  private var dataAllocated: UInt64 = 0
  private var allAllocated: UInt64 = 0
  private var returned: UInt8 = 0

  var startIndex: Int { 0 }
  var endIndex: Int { 4 }

  subscript(index: Int) -> UInt64? {
    get {
      precondition((0..<4).contains(index))
      guard returned & (1 << index) != 0 else { return nil }
      switch index {
      case 0: return dataLogical
      case 1: return allLogical
      case 2: return dataAllocated
      default: return allAllocated
      }
    }
    set {
      precondition((0..<4).contains(index))
      let bit: UInt8 = 1 << index
      if newValue != nil { returned |= bit } else { returned &= ~bit }
      let value = newValue ?? 0
      switch index {
      case 0: dataLogical = value
      case 1: allLogical = value
      case 2: dataAllocated = value
      default: allAllocated = value
      }
    }
  }
}

/// Aggregates retain the same checked addition in Scanner.add. Collection
/// conformance keeps the original field order and serialization operations.
struct MetricTotals: MutableCollection, RandomAccessCollection {
  typealias Index = Int
  typealias Element = UInt64

  var dataLogical: UInt64 = 0
  var allLogical: UInt64 = 0
  var dataAllocated: UInt64 = 0
  var allAllocated: UInt64 = 0

  var startIndex: Int { 0 }
  var endIndex: Int { 4 }

  subscript(index: Int) -> UInt64 {
    get {
      precondition((0..<4).contains(index))
      switch index {
      case 0: return dataLogical
      case 1: return allLogical
      case 2: return dataAllocated
      default: return allAllocated
      }
    }
    set {
      precondition((0..<4).contains(index))
      switch index {
      case 0: dataLogical = newValue
      case 1: allLogical = newValue
      case 2: dataAllocated = newValue
      default: allAllocated = newValue
      }
    }
  }
}

/// Separate, metadata-free layout controls. The original packed-parser controls
/// remain available through --self-test and are not substituted by these tests.
func layoutSelfTest() throws {
  func require(_ value: Bool, _ name: String) throws {
    guard value else { throw Failure.invalid(name) }
  }

  var metrics = CoreMetrics()
  try require(metrics.allSatisfy { $0 == nil }, "layout_missing")
  for index in 0..<4 {
    metrics[index] = UInt64(index)
  }
  try require(Array(metrics) == [0, 1, 2, 3], "layout_field_order")
  metrics[0] = nil
  try require(metrics[0] == nil && metrics[1] == 1, "layout_clear_support")
  metrics[0] = 0
  try require(metrics[0] == 0, "layout_returned_zero")
  var equal = CoreMetrics()
  for index in 0..<4 { equal[index] = UInt64(index) }
  try require(equal == metrics, "layout_value_equality")

  let first = ObjectID(device: 1, inode: 2)
  let second = ObjectID(device: 2, inode: 2)
  let third = ObjectID(device: 1, inode: 3)
  try require(Set([first, first, second, third]).count == 3, "layout_identity_pair")

  var totals = MetricTotals(dataLogical: 1, allLogical: 2, dataAllocated: 3, allAllocated: 4)
  try require(Array(totals) == [1, 2, 3, 4], "layout_total_order")
  totals[2] += 5
  try require(totals.dataAllocated == 8, "layout_total_writeback")

  let options = try Options([
    "--lane", "bulk", "--root",
    FileManager.default.currentDirectoryPath + "/.build/b06-analyzer/selftest/fixtures/layout",
    "--expected-dev", "1", "--expected-ino", "1", "--session", "layout-selftest", "--summary-only",
  ])
  let scanner = Scanner(options)
  scanner.outputFailed = true  // Suppress protocol output in metadata-free tests.
  var maximum = MetricTotals(dataLogical: UInt64.max)
  do {
    try scanner.add(1, to: &maximum, at: 0)
    throw Failure.invalid("layout_overflow_missed")
  } catch Failure.invalid(let code) where code == "overflow" {}
  try require(maximum.dataLogical == UInt64.max, "layout_overflow_retains_value")

  var observation = Observation()
  observation.name = Data("first".utf8)
  observation.dev = 1
  observation.ino = 2
  observation.links = 3
  observation.flags = 0
  observation.type = 1
  for index in 0..<4 { observation.values[index] = UInt64(7 + index) }
  try scanner.accept(observation, Data())
  observation.name = Data("second".utf8)
  try scanner.accept(observation, Data())
  try require(
    scanner.objects.count == 1 && scanner.objects[first]?.edges == 2, "layout_hardlink_identity")
  try require(
    scanner.totals.dataLogical == 14 && scanner.objectTotals.dataLogical == 7,
    "layout_hardlink_totals")
  observation.name = Data("changed".utf8)
  observation.values[0] = 8
  try scanner.accept(observation, Data())
  try require(
    !scanner.complete && scanner.reason == "object_changed", "layout_changed_object_partial")
  try require(scanner.objects[first]?.values[0] == 7, "layout_first_observation_retained")

  try require(MemoryLayout<CoreMetrics>.stride == 40, "layout_metrics_inline_stride")
  try require(MemoryLayout<MetricTotals>.stride == 32, "layout_totals_inline_stride")
  try require(MemoryLayout<ObjectID>.stride == 16, "layout_identity_inline_stride")
  print(
    "{\"kind\":\"layout-selftest\",\"schema\":1,\"passed\":16,\"metrics_stride\":40,\"totals_stride\":32,\"identity_stride\":16}"
  )
}
