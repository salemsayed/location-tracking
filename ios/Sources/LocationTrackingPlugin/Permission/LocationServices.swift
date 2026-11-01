import Foundation
import CoreLocation

final class LocationServices {
    static let shared = LocationServices()
    private(set) var enabled = true
    private let read: () -> Bool
    init(read: @escaping () -> Bool = { CLLocationManager.locationServicesEnabled() }) { self.read = read }
    func refresh(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let enabled = self.read()
            DispatchQueue.main.async {
                self.enabled = enabled
                completion?()
            }
        }
    }
}
