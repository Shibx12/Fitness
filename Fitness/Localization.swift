import Foundation

enum L10n {
    static func string(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }
}
