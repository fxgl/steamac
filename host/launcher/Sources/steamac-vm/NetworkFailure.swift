import Foundation

/// Friendly download errors without changing URLSession's system TLS/trust policy.
/// The original error must still be logged by the caller.
enum NetworkFailure {
    enum Server {
        case valve, updates
        var name: String { self == .valve ? "Valve's servers" : "the update server (GitHub)" }
    }

    static func message(_ error: Error, server: Server) -> String {
        message(error, server: server, localized: false)
    }

    static func localizedMessage(_ error: Error, server: Server) -> String {
        message(error, server: server, localized: true)
    }

    private static func message(_ error: Error, server: Server, localized: Bool) -> String {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return localized ? error.localizedDescription : "\(error)" }
        switch e.code {
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection:
            if localized {
                return server == .valve
                    ? String(localized: "Can't reach Valve's servers securely. A VPN, proxy, or network filter may be interfering; try without it or on another network. Technical details are in the launcher log.")
                    : String(localized: "Can't reach the update server (GitHub) securely. A VPN, proxy, or network filter may be interfering; try without it or on another network. Technical details are in the launcher log.")
            }
            return "Can't reach \(server.name) securely. A VPN, proxy, or network filter may be interfering; try without it or on another network. Technical details are in the launcher log."
        case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive, NSURLErrorDataNotAllowed:
            if localized {
                return server == .valve
                    ? String(localized: "Can't reach Valve's servers. Check your internet connection. A VPN, proxy, or network filter may be interfering; try without it or on another network. Technical details are in the launcher log.")
                    : String(localized: "Can't reach the update server (GitHub). Check your internet connection. A VPN, proxy, or network filter may be interfering; try without it or on another network. Technical details are in the launcher log.")
            }
            return "Can't reach \(server.name). Check your internet connection. A VPN, proxy, or network filter may be interfering; try without it or on another network. Technical details are in the launcher log."
        default:
            return e.localizedDescription
        }
    }
}
