import CryptoKit
import Foundation
import Security

/// A RAUC "plain" bundle (.raucb): squashfs payload + detached CMS signature (DER) + the
/// signature size as 8 bytes big-endian. Verified like scripts/steps/10-rootfs.sh and RAUC on the
/// device: the CMS signature over the squashfs must chain to Valve's RAUC CA
/// "CN=steamdeck-images, O=Valve Corp" — that certificate only (Security.framework; the system
/// trust store is never consulted).
struct RaucBundle {
    /// SHA-256 of the DER of scripts/keys/steamdeck-images.pem (= STEAMOS_CA_FP_SHA256 in config.env).
    static let caFingerprint = "D562FEFE251B76EAB0E9E999354AD186B8EB2E2FB3450FADBEC7F6AA59B602D9"

    struct DevelopmentSignature: LocalizedError, CustomStringConvertible {
        var description: String {
            "This SteamOS build is signed with Valve's development key (steamos-dev-images) and can't be verified; choose stable or try again later."
        }
        var errorDescription: String? {
            String(localized: "This SteamOS build is signed with Valve's development key (steamos-dev-images) and can't be verified; choose stable or try again later.")
        }
    }

    /// Only a valid CMS signature whose leaf is the development signer gets this expected
    /// rejection. Never classify by the localised Security error text or by the chosen branch.
    static func trustFailure(signer: String, detail: String) -> Error {
        if signer == "steamos-dev-images" { return DevelopmentSignature() }
        return OptionError("bundle signature: certificate chain not trusted by the Valve CA: \(detail)")
    }

    struct Manifest {
        let compatible: String
        let version: String
        let rootfsSHA256: String
        let rootfsSize: UInt64
        let rootfsFilename: String
    }

    let squashfs: [UInt8]
    let signature: [UInt8]
    /// Subject CN of the signing certificate (after verify()).
    private(set) var signer = ""

    init(contentsOf path: String) throws {
        let d = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        guard d.count > 8 else { throw OptionError("\(path): not a RAUC bundle") }
        let sigSize = d[(d.count - 8)...].reduce(0) { $0 << 8 | Int($1) }
        guard sigSize > 0, sigSize < d.count - 8 else { throw OptionError("\(path): bad signature size \(sigSize)") }
        squashfs = Array(d[0..<(d.count - 8 - sigSize)])
        signature = Array(d[(d.count - 8 - sigSize)..<(d.count - 8)])
    }

    /// The pinned Valve CA (PEM file; its fingerprint must equal `caFingerprint`).
    static func loadCA(_ pemPath: String) throws -> SecCertificate {
        let pem = try String(contentsOfFile: pemPath, encoding: .utf8)
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64), let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw OptionError("\(pemPath): not a PEM certificate")
        }
        let fp = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        guard fp == caFingerprint else { throw OptionError("\(pemPath): CA fingerprint \(fp) is not the pinned Valve CA") }
        return cert
    }

    /// CMS signature over the squashfs, signer chain anchored at `ca` only.
    mutating func verify(ca: SecCertificate) throws {
        var decoder: CMSDecoder?
        try check(CMSDecoderCreate(&decoder), "CMSDecoderCreate")
        guard let decoder else { throw OptionError("CMSDecoderCreate returned nil") }
        try signature.withUnsafeBytes { try check(CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count), "CMSDecoderUpdateMessage") }
        try check(CMSDecoderSetDetachedContent(decoder, Data(squashfs) as CFData), "CMSDecoderSetDetachedContent")
        try check(CMSDecoderFinalizeMessage(decoder), "CMSDecoderFinalizeMessage")
        var signers = 0
        try check(CMSDecoderGetNumSigners(decoder, &signers), "CMSDecoderGetNumSigners")
        guard signers == 1 else { throw OptionError("bundle signature: \(signers) signers (expected 1)") }
        // Signature check only here (evaluateSecTrust false); the chain is evaluated below with
        // the Valve CA as the only anchor.
        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var certResult: OSStatus = 0
        try check(CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, &trust, &certResult),
                  "CMSDecoderCopySignerStatus")
        guard status == .valid else {
            throw OptionError("bundle signature: signer status \(status.rawValue) (\(RaucBundle.describe(status)))")
        }
        guard let trust else { throw OptionError("bundle signature: no signer trust") }
        try check(SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()), "SecTrustSetPolicies")
        try check(SecTrustSetAnchorCertificates(trust, [ca] as CFArray), "SecTrustSetAnchorCertificates")
        try check(SecTrustSetAnchorCertificatesOnly(trust, true), "SecTrustSetAnchorCertificatesOnly")
        try check(SecTrustSetNetworkFetchAllowed(trust, false), "SecTrustSetNetworkFetchAllowed")
        var err: CFError?
        guard SecTrustEvaluateWithError(trust, &err) else {
            var leaf: SecCertificate?
            try check(CMSDecoderCopySignerCert(decoder, 0, &leaf), "CMSDecoderCopySignerCert")
            var cn: CFString?
            if let leaf { SecCertificateCopyCommonName(leaf, &cn) }
            let detail = err.map { "\($0)" } ?? "?"
            let failure = RaucBundle.trustFailure(signer: (cn as String?) ?? "", detail: detail)
            if failure is DevelopmentSignature { log("bundle signature: development signer rejected: \(detail)") }
            throw failure
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let root = chain.last,
              SecCertificateCopyData(root) as Data == SecCertificateCopyData(ca) as Data else {
            throw OptionError("bundle signature: chain does not end at the Valve CA")
        }
        var cn: CFString?
        SecCertificateCopyCommonName(chain[0], &cn)
        signer = (cn as String?) ?? "?"
    }

    private static func describe(_ s: CMSSignerStatus) -> String {
        switch s {
        case .unsigned: return "unsigned"
        case .valid: return "valid"
        case .needsDetachedContent: return "needs detached content"
        case .invalidSignature: return "invalid signature"
        case .invalidCert: return "invalid certificate"
        case .invalidIndex: return "invalid index"
        @unknown default: return "unknown"
        }
    }

    private func check(_ s: OSStatus, _ what: String) throws {
        guard s == errSecSuccess else {
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? ""
            throw OptionError("\(what): \(s) \(msg)")
        }
    }

    /// manifest.raucm (INI): [update] compatible/version, [image.rootfs] sha256/size/filename.
    static func parseManifest(_ text: String) throws -> Manifest {
        var section = ""
        var kv: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            kv[section + "." + line[..<eq]] = String(line[line.index(after: eq)...])
        }
        guard let compatible = kv["update.compatible"], let sha = kv["image.rootfs.sha256"],
              let sizeText = kv["image.rootfs.size"], let size = UInt64(sizeText),
              let filename = kv["image.rootfs.filename"] else {
            throw OptionError("manifest.raucm: missing [update] compatible or [image.rootfs] sha256/size/filename")
        }
        guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { throw OptionError("manifest.raucm: bad sha256") }
        return Manifest(compatible: compatible, version: kv["update.version"] ?? "", rootfsSHA256: sha.lowercased(),
                        rootfsSize: size, rootfsFilename: filename)
    }
}
