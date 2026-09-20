import Darwin
import Foundation
import YCodeCore

if CommandLine.arguments.contains("--version") {
    print("ycode-notify \(YCodeBuildInfo.version)")
    exit(0)
}

private let invocation = parseArguments(Array(CommandLine.arguments.dropFirst()))
private let stdin = readStandardInput()
private let payload: [String: Any] = [
    "terminal_id": ProcessInfo.processInfo.environment["YCODE_TERMINAL_ID"] ?? "",
    "source": invocation.source,
    "event": invocation.event,
    "stdin": stdin,
    "extra": invocation.passthrough
]
if let data = try? JSONSerialization.data(withJSONObject: payload),
   let socketPath = ProcessInfo.processInfo.environment["YCODE_NOTIFY_SOCK"],
   !socketPath.isEmpty {
    send(data + Data("\n".utf8), to: socketPath)
}
if let next = invocation.next, !next.isEmpty {
    execute(next + invocation.passthrough)
}
exit(0)

private struct Invocation {
    var event = "stop"
    var source = "unknown"
    var next: [String]?
    var passthrough: [String] = []
}

private func parseArguments(_ arguments: [String]) -> Invocation {
    var invocation = Invocation()
    var position = 0
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--next", index + 1 < arguments.count {
            if let data = arguments[index + 1].data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String],
               !decoded.isEmpty {
                invocation.next = decoded
            }
            index += 2
            continue
        }
        switch position {
        case 0: invocation.event = argument
        case 1: invocation.source = argument
        default: invocation.passthrough.append(argument)
        }
        position += 1
        index += 1
    }
    return invocation
}

private func readStandardInput() -> String {
    guard isatty(STDIN_FILENO) == 0 else { return "" }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(decoding: data.prefix(64 * 1024), as: UTF8.self)
}

private func send(_ data: Data, to path: String) {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
    address.sun_family = sa_family_t(AF_UNIX)
    let length = offset + bytes.count
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(length))
        }
    }
    guard connected == 0 else { return }
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: sent), bytes.count - sent)
            if count <= 0 { return }
            sent += count
        }
    }
}

private func execute(_ arguments: [String]) -> Never {
    let duplicated = arguments.map { strdup($0) }
    defer { duplicated.forEach { free($0) } }
    var pointers = duplicated + [nil]
    pointers.withUnsafeMutableBufferPointer { buffer in
        if let executable = buffer[0] { _ = execvp(executable, buffer.baseAddress) }
    }
    exit(0)
}
