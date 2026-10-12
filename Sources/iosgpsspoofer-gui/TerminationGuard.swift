import Foundation
import SpooferCore

/// Last line of defence: if the app is ended by SIGTERM (a `kill`), SIGINT
/// (Ctrl-C when launched from a terminal) or SIGHUP (the terminal it was
/// launched from was closed) rather than a clean Cmd-Q, AppKit's terminate
/// hooks never run. So catch the signal ourselves, put every iPhone back to its
/// real location, stop any `pymobiledevice3` children, and exit. (Cmd-Q still
/// goes through the nicer `applicationShouldTerminate` path, which does the same.
/// SIGKILL and panics can't be caught: `ChildProcessRegistry.sweepStrays()` on
/// the next launch mops those up and puts the real location back too.)
enum TerminationGuard {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func install() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                // The live helper clears the location itself when its input closes,
                // but a classic hold doesn't: stop each session so that its iPhone
                // really gets its real location back, then stop whatever is left.
                SpoofSession.stopAllBlocking()
                ChildProcessRegistry.shared.terminateAll(grace: 2)
                UserDefaults.standard.synchronize()
                // `_exit`, not `exit`: this runs on a background queue while the main
                // thread is still working, and `exit` would run the app's shutdown
                // code under it.
                _exit(0)
            }
            source.resume()
            sources.append(source)
        }
    }
}
