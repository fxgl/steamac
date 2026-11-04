import Foundation
import Security
import CryptoKit
import CommonCrypto

enum StreamDER {
    static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        var result = Data([tag])
        if body.count < 128 { result.append(UInt8(body.count)) }
        else {
            var count = body.count
            var bytes = [UInt8]()
            repeat { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 } while count != 0
            result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes)
        }
        result.append(body)
        return result
    }
    static func sequence(_ parts: Data...) -> Data { tagged(0x30, parts.reduce(Data(), +)) }
    static func integer(_ value: Int) -> Data {
        var value = value
        var bytes = [UInt8]()
        repeat { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 } while value > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(2, Data(bytes))
    }
    static func oid(_ text: String) -> Data {
        let values = text.split(separator: ".").map { UInt64($0)! }
        var bytes = Data([UInt8(values[0] * 40 + values[1])])
        for var value in values.dropFirst(2) {
            var chunk = [UInt8(value & 127)]; value >>= 7
            while value > 0 { chunk.insert(UInt8(value & 127) | 0x80, at: 0); value >>= 7 }
            bytes.append(contentsOf: chunk)
        }
        return tagged(6, bytes)
    }
    static let rsa = sequence(oid("1.2.840.113549.1.1.1"), Data([5, 0]))
    static let rsaSHA256 = sequence(oid("1.2.840.113549.1.1.11"), Data([5, 0]))
    static func octet(_ data: Data) -> Data { tagged(4, data) }
    static func explicit(_ data: Data) -> Data { tagged(0xa0, data) }
    static func bits(_ data: Data) -> Data { tagged(3, Data([0]) + data) }
    static func content(_ data: Data) -> Data { sequence(oid("1.2.840.113549.1.7.1"), explicit(octet(data))) }

    struct Item {
        let tag: UInt8
        let bytes: Data
    }
    static func children(_ data: Data) throws -> [Item] {
        let bytes = [UInt8](data)
        var offset = 0
        var result = [Item]()
        while offset < bytes.count {
            guard offset + 2 <= bytes.count else { throw StreamError("Truncated DER") }
            let tag = bytes[offset]; offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, offset + count <= bytes.count else { throw StreamError("Invalid DER length") }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            guard length <= bytes.count - offset else { throw StreamError("Truncated DER value") }
            result.append(Item(tag: tag, bytes: Data(bytes[offset..<offset + length])))
            offset += length
        }
        return result
    }
    static func certificateSignature(_ cert: Data) throws -> Data {
        let outer = try children(cert)
        guard outer.count == 1, outer[0].tag == 0x30 else { throw StreamError("Invalid certificate") }
        let fields = try children(outer[0].bytes)
        guard fields.count == 3, fields[2].tag == 3, fields[2].bytes.first == 0 else { throw StreamError("Invalid certificate signature") }
        return Data(fields[2].bytes.dropFirst())
    }
}

enum StreamCrypto {
    static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }) == errSecSuccess else { throw StreamError("Secure random failed") }
        return bytes
    }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ string: String) -> Data? {
        let bytes = Array(string.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: return nil }
        }
        var data = Data(capacity: bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let a = nibble(bytes[i]), let b = nibble(bytes[i + 1]) else { return nil }
            data.append(a << 4 | b)
        }
        return data
    }
    static func pem(_ der: Data) -> Data {
        let base = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(base)\n-----END CERTIFICATE-----\n".utf8)
    }
    static func certificateDER(_ bytes: Data) throws -> Data {
        if SecCertificateCreateWithData(nil, bytes as CFData) != nil { return bytes }
        guard let text = String(data: bytes, encoding: .utf8),
              let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----"), start.upperBound <= end.lowerBound,
              let der = Data(base64Encoded: String(text[start.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters),
              SecCertificateCreateWithData(nil, der as CFData) != nil else { throw StreamError("Invalid client certificate") }
        return der
    }
    static func sign(_ data: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let result = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) else { throw StreamError("RSA signing failed: \(String(describing: error?.takeRetainedValue()))") }
        return result as Data
    }
    static func verify(_ data: Data, signature: Data, certificate: Data) -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData), let key = SecCertificateCopyKey(cert) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    }
    static func crypt(_ data: Data, key: Data, iv: Data? = nil, encrypt: Bool, tripleDES: Bool = false) throws -> Data {
        var output = Data(count: data.count + 32)
        var count = 0
        let options = tripleDES ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(kCCOptionECBMode)
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    if let iv {
                        return iv.withUnsafeBytes { ivBytes in
                            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(tripleDES ? kCCAlgorithm3DES : kCCAlgorithmAES), options, keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count, out.baseAddress, capacity, &count)
                        }
                    }
                    return CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options, keyBytes.baseAddress, key.count, nil, input.baseAddress, data.count, out.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw StreamError("Pairing cipher failed (\(status))") }
        output.count = count
        return output
    }
    // RFC 7292, appendix B: SHA-1 diversifier KDF (not PBKDF2).
    static func pkcs12KDF(password: String, salt: Data, id: UInt8, count: Int, rounds: Int) -> Data {
        var passwordBytes = Data()
        for unit in password.utf16 { passwordBytes.append(UInt8(unit >> 8)); passwordBytes.append(UInt8(unit & 255)) }
        passwordBytes.append(contentsOf: [0, 0])
        func expanded(_ data: Data) -> [UInt8] {
            guard !data.isEmpty else { return [] }
            return (0..<((data.count + 63) / 64 * 64)).map { data[$0 % data.count] }
        }
        var input = expanded(salt) + expanded(passwordBytes)
        let diversifier = Data(repeating: id, count: 64)
        var output = Data()
        while output.count < count {
            var a = sha1(diversifier + Data(input))
            for _ in 1..<rounds { a = sha1(a) }
            output.append(a)
            let b = (0..<64).map { a[$0 % 20] }
            for block in stride(from: 0, to: input.count, by: 64) {
                var carry = 1
                for j in (0..<64).reversed() {
                    let sum = Int(input[block + j]) + Int(b[j]) + carry
                    input[block + j] = UInt8(sum & 255); carry = sum >> 8
                }
            }
        }
        return Data(output.prefix(count))
    }
    static func pkcs12(key: Data, certificate: Data, password: String) throws -> Data {
        let salt = try random(16)
        let rounds = 2048
        let derived = pkcs12KDF(password: password, salt: salt, id: 1, count: 24, rounds: rounds)
        let iv = pkcs12KDF(password: password, salt: salt, id: 2, count: 8, rounds: rounds)
        let keyInfo = StreamDER.sequence(StreamDER.integer(0), StreamDER.rsa, StreamDER.octet(key))
        let encrypted = try crypt(keyInfo, key: derived, iv: iv, encrypt: true, tripleDES: true)
        let pbe = StreamDER.sequence(StreamDER.oid("1.2.840.113549.1.12.1.3"), StreamDER.sequence(StreamDER.octet(salt), StreamDER.integer(rounds)))
        let keyID = sha1(certificate)
        let attributes = StreamDER.tagged(0x31, StreamDER.sequence(StreamDER.oid("1.2.840.113549.1.9.21"), StreamDER.tagged(0x31, StreamDER.octet(keyID))))
        let keyBag = StreamDER.sequence(StreamDER.oid("1.2.840.113549.1.12.10.1.2"), StreamDER.explicit(StreamDER.sequence(pbe, StreamDER.octet(encrypted))), attributes)
        let certBag = StreamDER.sequence(StreamDER.oid("1.2.840.113549.1.12.10.1.3"), StreamDER.explicit(StreamDER.sequence(StreamDER.oid("1.2.840.113549.1.9.22.1"), StreamDER.explicit(StreamDER.octet(certificate)))), attributes)
        let safe = StreamDER.sequence(StreamDER.content(StreamDER.sequence(keyBag, certBag)))
        let macSalt = try random(16)
        let macKey = pkcs12KDF(password: password, salt: macSalt, id: 3, count: 20, rounds: rounds)
        var mac = Data(count: 20)
        mac.withUnsafeMutableBytes { output in macKey.withUnsafeBytes { k in safe.withUnsafeBytes { s in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), k.baseAddress, macKey.count, s.baseAddress, safe.count, output.baseAddress)
        } } }
        let digestInfo = StreamDER.sequence(StreamDER.sequence(StreamDER.oid("1.3.14.3.2.26"), Data([5, 0])), StreamDER.octet(mac))
        return StreamDER.sequence(StreamDER.integer(3), StreamDER.content(safe), StreamDER.sequence(digestInfo, StreamDER.octet(macSalt), StreamDER.integer(rounds)))
    }
}
