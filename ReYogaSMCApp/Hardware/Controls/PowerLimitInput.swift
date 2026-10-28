import Foundation

struct PowerLimitInput {
    static func digits(_ input: String) -> String { String(input.filter { $0 >= "0" && $0 <= "9" }.prefix(5)) }
    static func isValid(_ input: String, range: [String: Int]) -> Bool {
        guard !input.isEmpty, input == digits(input), let value = Int(input),
              let low = range["Min"], let high = range["Max"], let step = range["Step"],
              low >= 0, high >= low, step > 0 else { return false }
        return value >= low && value <= high && (value - low) % step == 0
    }
}
