import Foundation

/// Matches the old backend's 256 KiB terminal replay contract while keeping
/// ANSI control bytes intact. A newly-created view replays this buffer before
/// it starts receiving live output.
struct BoundedByteBacklog: Sendable {
    let capacity: Int
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 256 * 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func append(_ incoming: ArraySlice<UInt8>) {
        guard !incoming.isEmpty else { return }
        if incoming.count >= capacity {
            bytes = Array(incoming.suffix(capacity))
            return
        }

        let overflow = bytes.count + incoming.count - capacity
        if overflow > 0 {
            bytes.removeFirst(overflow)
        }
        bytes.append(contentsOf: incoming)
    }
}

enum DecodedWaitStatus: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case stopped(Int32)
}

/// SwiftTerm 1.20.0 exposes waitpid's raw status. Decode it at our boundary so
/// callers never mistake `42 << 8` for the actual exit code.
func decodeWaitStatus(_ raw: Int32) -> DecodedWaitStatus {
    let signal = raw & 0x7f
    if signal == 0 { return .exited((raw >> 8) & 0xff) }
    if signal == 0x7f { return .stopped((raw >> 8) & 0xff) }
    return .signaled(signal)
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func terminalEnvironment(from source: [String: String]) -> [String: String] {
    var environment = source
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["FORCE_COLOR"] = "1"
    environment["CLICOLOR"] = "1"
    environment["CLICOLOR_FORCE"] = "1"
    environment.removeValue(forKey: "NO_COLOR")
    return environment
}

func zshTotalSeconds(in text: String) -> Double? {
    guard let expression = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?) total"#) else {
        return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = expression.matches(in: text, range: range).last,
          let valueRange = Range(match.range(at: 1), in: text) else { return nil }
    return Double(text[valueRange])
}
