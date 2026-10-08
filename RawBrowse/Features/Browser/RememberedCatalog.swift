import Foundation

struct RememberedCatalog: Codable, Identifiable, Equatable {
    var id: String {
        path
    }

    let path: String
    let bookmarkData: Data?
}
