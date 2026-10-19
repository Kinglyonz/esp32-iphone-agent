import Foundation

struct TrialLease: Decodable {
    let leaseID: String
    let leaseToken: String
    let generation: Int
    let remainingSeconds: Double

    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id", leaseToken = "lease_token", generation, remainingSeconds = "remaining_seconds"
    }
}

struct TrialLeaseUpdate: Decodable {
    let remainingSeconds: Double
    let generation: Int
    enum CodingKeys: String, CodingKey { case remainingSeconds = "remaining_seconds", generation }
}
