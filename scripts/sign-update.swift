// Signs release zips so the app's updater can tell they came from us.
//   swift scripts/sign-update.swift keygen        create the key and print the public half for Updater.swift
//   swift scripts/sign-update.swift sign <file>   print the file's signature, base64
// The private key lives outside the repo, at $SIDY_SIGNING_KEY or ~/.config/sidy/update-signing-key.
// Keep a copy somewhere safe: without it, installed copies can't take another update.
import CryptoKit
import Foundation

let keyFile = ProcessInfo.processInfo.environment["SIDY_SIGNING_KEY"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/sidy/update-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    guard !FileManager.default.fileExists(atPath: keyFile.path) else { fail("\(keyFile.path) already exists") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print("Saved the private key to \(keyFile.path)")
    print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign" where args.count == 2:
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyFile.path)") }
    guard let file = try? Data(contentsOf: URL(fileURLWithPath: args.last!)) else { fail("Can't read \(args.last!)") }
    print(try key.signature(for: file).base64EncodedString())
default:
    fail("usage: sign-update.swift keygen | sign <file>")
}
