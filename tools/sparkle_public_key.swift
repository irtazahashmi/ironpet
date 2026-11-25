// Prints the Sparkle public key (the SUPublicEDKey value) for a private key.
// Usage: printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | swift tools/sparkle_public_key.swift
// The private key is the base64 of the 32-byte seed that `generate_keys -x` writes. It is read from standard input, not from an
// argument, so it stays out of the process list. scripts/make_appcast.sh uses this to check that the signing key matches the app.
import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
guard let seed = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("error: not the base64 of a 32-byte seed\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
