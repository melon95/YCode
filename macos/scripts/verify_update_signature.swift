import CryptoKit
import Foundation

// All arguments are public metadata. Private update keys never enter this tool.
let args = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard args.count == 4,
      let publicKey = Data(base64Encoded: args[1]), publicKey.count == 32,
      let signature = Data(base64Encoded: args[3]), signature.count == 64 else {
    fail("usage: verify_update_signature.swift <public-key> <archive> <signature>")
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else { fail("Invalid Sparkle update signature") }
} catch { fail("Update verification failed: \(error.localizedDescription)") }
