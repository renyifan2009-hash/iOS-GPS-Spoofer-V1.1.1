import RemoteAPI

/// The controls can send commands to a Mac or execute them entirely on this phone.
@MainActor
protocol ControlTarget: AnyObject {
    var status: RemoteStatus? { get }
    var isSpoofing: Bool { get }
    var isWorking: Bool { get }
    var executionName: String { get }
    func steer(heading: Double, speed: Double) async -> String?
    @discardableResult func stop() async -> Bool
    @discardableResult func setPaused(_ paused: Bool) async -> Bool
    @discardableResult func setAutoStop(minutes: Int) async -> Bool
}

extension ConnectionManager: ControlTarget {
    var executionName: String { "Mac" }
}
