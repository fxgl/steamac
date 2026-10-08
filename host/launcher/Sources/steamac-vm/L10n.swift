import Foundation

/// Localized UI string lookup (Simplified Chinese via zh-Hans.lproj, English fallback).
/// Keys are the English source strings, so unknown/dynamic strings pass through unchanged —
/// wrapping is idempotent: `tr(tr(x)) == tr(x)`.
/// ponytail: one lookup point instead of NSLocalizedString boilerplate at 60+ call sites.
func tr(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string: `tr("DPI: %@", "110")`.
func tr(_ format: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(format, comment: ""), arguments: args)
}
