import Foundation
import SpooferCore

/// Thread-safe holder for the currently-running child process.
final class ChildBox: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?

    func set(_ process: Process?) {
        lock.lock(); defer { lock.unlock() }
        child = process
    }

    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        guard let child, child.isRunning else { return }
        child.interrupt() // SIGINT — pymobiledevice3 unwinds its tunnel cleanly
    }

    func waitUntilExit() {
        lock.lock()
        let c = child
        lock.unlock()
        c?.waitUntilExit()
    }
}

/// Keeps a long-running pymobiledevice3 child alive for the lifetime of the
/// tool, relaunching it if the device drops and comes back, and clearing the
/// simulated location on exit.
struct Supervisor {
    let ctx: Context
    let childArgs: [String]
    let describe: String
    let retryInterval: TimeInterval
    let clearOnExit: Bool
    /// A child that exits successfully has done its job and the location
    /// persists (iOS ≤ 16 `set`, or a finished route): hold until Ctrl-C,
    /// re-applying only if the device goes away and comes back.
    var holdAfterSuccessfulExit = false

    func run() throws {
        let watcher = ShutdownWatcher()
        let childBox = ChildBox()
        watcher.install { childBox.interrupt() }

        ctx.preflight()
        log("target: \(ctx.device.summary)")

        while !watcher.isRequested {
            guard ctx.pmd.isPresent(udid: ctx.device.udid, connection: ctx.connection) else {
                log("device not connected — waiting…")
                sleepInterruptibly(retryInterval, watcher)
                continue
            }

            let child: Process
            do {
                child = try ctx.pmd.spawn(childArgs)
            } catch {
                warn("could not start pymobiledevice3: \(error)")
                sleepInterruptibly(retryInterval, watcher)
                continue
            }
            childBox.set(child)
            log("● GPS spoof ACTIVE — \(describe). Press Ctrl-C to stop.")
            child.waitUntilExit()
            childBox.set(nil)

            if watcher.isRequested { break }
            if holdAfterSuccessfulExit && child.terminationStatus == 0 {
                log("● holding. Press Ctrl-C to stop and restore the real location.")
                waitWhilePresent(watcher)
                if watcher.isRequested { break }
                log("device reconnected — re-applying")
                continue
            }
            warn("session ended (status \(child.terminationStatus)) — re-establishing in \(Int(retryInterval))s")
            sleepInterruptibly(retryInterval, watcher)
        }

        childBox.interrupt()
        childBox.waitUntilExit()

        if clearOnExit {
            log("restoring real GPS…")
            do {
                _ = try ctx.pmd.run(ctx.clearArguments, timeout: 90)
                log("real GPS restored.")
            } catch {
                warn("could not clear simulated location: \(firstLine(error))\nRun `iosgpsspoof clear` to restore it.")
            }
        }
        log("stopped.")
    }

    /// Return when shutdown is requested, or once the device has disappeared
    /// and come back (so the caller re-applies the location).
    private func waitWhilePresent(_ watcher: ShutdownWatcher) {
        var wentAway = false
        while !watcher.isRequested {
            sleepInterruptibly(5, watcher)
            if watcher.isRequested { return }
            let present = ctx.pmd.isPresent(udid: ctx.device.udid, connection: ctx.connection)
            if !present && !wentAway {
                wentAway = true
                log("device disconnected — will re-apply when it returns")
            } else if present && wentAway {
                return
            }
        }
    }
}

/// Sleep in small slices so a shutdown signal is honoured promptly.
func sleepInterruptibly(_ seconds: TimeInterval, _ watcher: ShutdownWatcher) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline && !watcher.isRequested {
        usleep(200_000)
    }
}
