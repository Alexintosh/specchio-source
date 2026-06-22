import SwiftUI

protocol DisplayProvider: ObservableObject {
    var isActive: Bool { get }
    var currentFPS: Double { get }
    func start() async
    func stop()
}
