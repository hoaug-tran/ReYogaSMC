import Foundation

// Only discovery fields are typed; packet and zone validation stays at its existing boundary.
struct RGBMatchProfile {
    let profile: [String: Any]
    let vendorID: Int
    let productID: Int
    let usagePage: Int
    let usage: Int
    let reportSize: Int?

    init?(_ profile: [String: Any]) {
        guard let vendorID = profile["vendorID"] as? Int,
              let productID = profile["productID"] as? Int,
              let usagePage = profile["usagePage"] as? Int,
              let usage = profile["usage"] as? Int else { return nil }
        self.profile = profile
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
        reportSize = profile["reportSize"] as? Int
    }

    func matches(vendorID: Int?, productID: Int?, usagePage: Int?, usage: Int?) -> Bool {
        guard self.vendorID == vendorID && self.productID == productID && self.usagePage == usagePage else { return false }
        if self.usage == usage { return true }
        if (self.usage == 16 || self.usage == 7) && (usage == 16 || usage == 7) { return true }
        return false
    }
}
