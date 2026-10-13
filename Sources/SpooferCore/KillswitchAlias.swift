import PhoneOnlyCore

/// Auto-stop's rules (presets, parsing, wording, countdown) live in `PhoneOnlyCore`, where the iPhone app
/// uses them too. The Mac code keeps saying `Killswitch`.
public typealias Killswitch = PhoneOnlyCore.Killswitch
