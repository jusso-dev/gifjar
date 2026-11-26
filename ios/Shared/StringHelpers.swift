import Foundation

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
