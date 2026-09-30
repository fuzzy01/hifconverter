import Foundation

/// Peak and reference white for the HLG look. ImageIO already applies the
/// transfer, so these numbers are only the headroom passed to the content tag.
enum HLGFormula {
    static let referenceWhiteNits = 203.0
    static let defaultPeakNits = 1000.0
}
