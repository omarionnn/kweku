import Foundation

/// Minimal zero-dependency test harness (XCTest is unavailable under Command
/// Line Tools, and third-party deps are forbidden). Collects failures and
/// exits non-zero so CI / `make test` can gate on it.
enum Check {
    static var total = 0
    static var failures = 0

    static func ok(_ condition: Bool, _ message: @autoclosure () -> String,
                   file: StaticString = #fileID, line: UInt = #line) {
        total += 1
        if !condition {
            failures += 1
            print("  FAIL [\(file):\(line)] \(message())")
        }
    }

    static func eq(_ a: Double, _ b: Double, accuracy: Double = 0.001,
                   _ message: @autoclosure () -> String,
                   file: StaticString = #fileID, line: UInt = #line) {
        ok(abs(a - b) <= accuracy,
           "\(message()) — got \(a), want \(b) (±\(accuracy))",
           file: file, line: line)
    }

    static func run(_ name: String, _ body: () -> Void) {
        let before = failures
        body()
        let status = failures == before ? "ok" : "FAILED"
        print("- \(name): \(status)")
    }

    static func finish() -> Never {
        print("\n\(total - failures)/\(total) checks passed" +
              (failures == 0 ? " ✓" : "  (\(failures) FAILED)"))
        exit(failures == 0 ? 0 : 1)
    }
}
