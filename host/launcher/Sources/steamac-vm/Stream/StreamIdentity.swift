import Foundation
import Security
import Darwin

final class StreamIdentity {
    static var defaultDirectory: String {
        ProcessInfo.processInfo.environment["STEAMAC_STREAM_DIR"] ?? (AppBundle.appSupportDir + "/moonlight")
    }
    let directory: String
    let uniqueID: String
    let certificateDER: Data
    let privateKey: SecKey
    let tlsIdentity: SecIdentity
    let signature: Data

    static func loadOrCreate(directory: String = StreamIdentity.defaultDirectory) throws -> StreamIdentity {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory, 0o700) == 0 else { throw StreamError("Cannot protect streaming identity directory") }
        let keyPath = directory + "/key.der"
        let certPath = directory + "/certificate.der"
        let idPath = directory + "/uniqueid"
        let paths = [keyPath, certPath, idPath]
        let existing = paths.filter { fm.fileExists(atPath: $0) }
        if !existing.isEmpty {
            guard existing.count == paths.count else { throw StreamError("Incomplete streaming identity in \(directory)") }
            for path in paths { guard chmod(path, 0o600) == 0 else { throw StreamError("Cannot protect streaming identity file") } }
            let keyDER = try Data(contentsOf: URL(fileURLWithPath: keyPath))
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(keyDER as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error),
                  let id = String(data: try Data(contentsOf: URL(fileURLWithPath: idPath)), encoding: .utf8), UUID(uuidString: id) != nil else { throw StreamError("Invalid streaming identity") }
            return try StreamIdentity(directory: directory, uniqueID: id, certificate: Data(contentsOf: URL(fileURLWithPath: certPath)), key: key, keyDER: keyDER)
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false] as CFDictionary, &error),
              let keyData = SecKeyCopyExternalRepresentation(key, &error),
              let publicKey = SecKeyCopyPublicKey(key), let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) else { throw StreamError("Cannot create RSA streaming identity") }
        let name = StreamDER.sequence(StreamDER.tagged(0x31, StreamDER.sequence(StreamDER.oid("2.5.4.3"), StreamDER.tagged(12, Data("SteamAC GameStream".utf8)))))
        let validity = StreamDER.sequence(StreamDER.tagged(0x17, Data("200101000000Z".utf8)), StreamDER.tagged(0x18, Data("20500101000000Z".utf8)))
        var serial = try StreamCrypto.random(16)
        serial[0] = (serial[0] & 0x7f) | 0x40
        let tbs = StreamDER.sequence(StreamDER.explicit(StreamDER.integer(2)), StreamDER.tagged(2, serial), StreamDER.rsaSHA256, name, validity, name,
                                     StreamDER.sequence(StreamDER.rsa, StreamDER.bits(publicData as Data)))
        let cert = StreamDER.sequence(tbs, StreamDER.rsaSHA256, StreamDER.bits(try StreamCrypto.sign(tbs, key: key)))
        let id = UUID().uuidString
        let identity = try StreamIdentity(directory: directory, uniqueID: id, certificate: cert, key: key, keyDER: keyData as Data)
        try protectedWrite(keyData as Data, to: keyPath)
        try protectedWrite(cert, to: certPath)
        try protectedWrite(Data(id.utf8), to: idPath)
        return identity
    }

    private init(directory: String, uniqueID: String, certificate: Data, key: SecKey, keyDER: Data) throws {
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData),
              let publicKey = SecCertificateCopyKey(cert) else { throw StreamError("Invalid host certificate") }
        let probe = Data("steamac identity".utf8)
        guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, probe as CFData, try StreamCrypto.sign(probe, key: key) as CFData, nil) else { throw StreamError("Streaming certificate and key do not match") }
        let password = "steamac-memory-only"
        let p12 = try StreamCrypto.pkcs12(key: keyDER, certificate: certificate, password: password)
        var imported: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true] as CFDictionary, &imported)
        guard status == errSecSuccess, let items = imported as? [[String: Any]], let item = items.first,
              let identity = item[kSecImportItemIdentity as String] else { throw StreamError("Cannot import in-memory TLS identity (\(status))") }
        self.directory = directory
        self.uniqueID = uniqueID
        certificateDER = certificate
        privateKey = key
        tlsIdentity = identity as! SecIdentity
        signature = try StreamDER.certificateSignature(certificate)
    }

    static func protectedWrite(_ data: Data, to path: String) throws {
        let temp = path + "." + UUID().uuidString
        guard FileManager.default.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o600]) else { throw StreamError("Cannot save streaming identity") }
        guard rename(temp, path) == 0 else { try? FileManager.default.removeItem(atPath: temp); throw StreamError("Cannot commit streaming identity") }
    }
}
