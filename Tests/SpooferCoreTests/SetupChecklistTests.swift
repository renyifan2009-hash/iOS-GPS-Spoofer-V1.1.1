import XCTest
import SpooferCore

/// The first-run checklist (Logic/SetupChecklist.swift, linked into this test target as GUILogic).
final class SetupChecklistTests: XCTestCase {
    private let phone = SetupInputs.IPhone(name: "Demo iPhone", model: "iPhone 14 Pro", iOS: "17.5", trusted: true)

    private func inputs(_ edit: (inout SetupInputs) -> Void = { _ in }) -> SetupInputs {
        var i = SetupInputs(helperInstalled: true, helperVersion: "5.0.1", iPhone: phone, hasLookedForDevices: true,
                            developerMode: true, developerSupport: .later, engine: .live(version: "5.0.1"))
        edit(&i)
        return i
    }

    private func row(_ id: String, _ i: SetupInputs) -> SetupCheck {
        SetupChecklist.checks(i).first { $0.id == id }!
    }

    // MARK: The developer support step

    func testThereIsARowForAppleDeveloperSupport() {
        let ids = SetupChecklist.checks(inputs()).map(\.id)
        XCTAssertEqual(ids, ["tool", "device", "devmode", "support", "engine"])
    }

    func testBeforeTheFirstTeleportTheRowExplainsWhatWillHappen() {
        // The tester pressed Teleport and waited on a spinner with no idea why.
        let support = row("support", inputs())
        XCTAssertEqual(support.state, .later)
        XCTAssertTrue(support.detail.contains("Needs the internet once"), support.detail)
        XCTAssertTrue(support.detail.contains("Keep the iPhone unlocked"), support.detail)
        XCTAssertNil(support.fix)
    }

    func testTheRowFollowsTheSession() {
        XCTAssertEqual(row("support", inputs { $0.developerSupport = .settingUp }).state, .pending)
        XCTAssertEqual(row("support", inputs { $0.developerSupport = .ready }).state, .ok)
        let trouble = row("support", inputs { $0.developerSupport = .trouble })
        XCTAssertEqual(trouble.state, .warning)
        XCTAssertEqual(trouble.fix, .connectionHelp)
        XCTAssertTrue(trouble.detail.contains("online"), trouble.detail)
    }

    func testNewCopyIsPlain() {
        for state in [DeveloperSupportState.later, .settingUp, .ready, .trouble] {
            let r = row("support", inputs { $0.developerSupport = state })
            XCTAssertFalse(r.detail.contains("—"), r.detail)
            XCTAssertFalse(r.detail.contains(";"), r.detail)
            XCTAssertFalse(r.detail.lowercased().contains("disk image"), "one name for it: \(r.detail)")
            XCTAssertFalse(r.detail.lowercased().contains("mount"), r.detail)
        }
        XCTAssertFalse(SessionWording.settingUpDeveloperSupport.contains("—"))
        XCTAssertFalse(SessionWording.settingUpDeveloperSupport.contains(";"))
    }

    // MARK: Reading the session

    func testSessionMessagesMapToTheRightState() {
        // What SpoofSession reports while it loads the support, and when that fails.
        XCTAssertEqual(DeveloperSupportState.resolve(connecting: "Mounting the developer disk image…", reconnecting: nil, ready: false),
                       .settingUp)
        XCTAssertEqual(DeveloperSupportState.resolve(connecting: "Checking the live engine…", reconnecting: nil, ready: false), .later)
        XCTAssertEqual(DeveloperSupportState.resolve(connecting: nil, reconnecting: nil, ready: true), .ready)
        XCTAssertEqual(DeveloperSupportState.resolve(connecting: nil, reconnecting: nil, ready: false), .later)
    }

    func testTheRetryAdviceFromTheCoreIsRecognisedAsTrouble() {
        // Tied to the real wording in SpooferCore, so a rewording there can't silently break the row.
        for error in ["developerdiskimage not mounted", "InvalidService", "mount failed"] {
            guard let message = SpoofSession.advice(for: error)?.message else { return XCTFail(error) }
            XCTAssertTrue(SessionWording.isDeveloperSupportTrouble(message), message)
            XCTAssertEqual(DeveloperSupportState.resolve(connecting: nil, reconnecting: message, ready: true), .trouble)
        }
        // Other retry advice is not about developer support.
        let dropped = SpoofSession.advice(for: "connection reset by peer")!.message
        XCTAssertFalse(SessionWording.isDeveloperSupportTrouble(dropped))
    }

    func testTheConnectingStatusSaysThePlainThing() {
        let friendly = SessionWording.friendly(connecting: "Mounting the developer disk image…")
        XCTAssertEqual(friendly, SessionWording.settingUpDeveloperSupport)
        XCTAssertTrue(friendly.contains("Needs the internet once"))
        // Anything else passes through untouched.
        XCTAssertEqual(SessionWording.friendly(connecting: "Checking the live engine…"), "Checking the live engine…")
    }

    // MARK: "All set"

    func testAllSetDoesNotWaitForTheFirstTeleport() {
        XCTAssertTrue(SetupChecklist.isComplete(SetupChecklist.checks(inputs())))
    }

    func testAllSetAlsoShowsOnTheClassicEngine() {
        // The classic engine works, so its warning row must not hide "All set" forever.
        let checks = SetupChecklist.checks(inputs { $0.engine = .classicOnly })
        XCTAssertEqual(checks.first { $0.id == "engine" }?.state, .warning)
        XCTAssertTrue(SetupChecklist.isComplete(checks))
    }

    func testAllSetStillWaitsForRealProblems() {
        XCTAssertFalse(SetupChecklist.isComplete(SetupChecklist.checks(inputs { $0.helperInstalled = false })))
        XCTAssertFalse(SetupChecklist.isComplete(SetupChecklist.checks(inputs { $0.iPhone = nil })))
        XCTAssertFalse(SetupChecklist.isComplete(SetupChecklist.checks(inputs { $0.developerMode = false })))
        // Developer Mode not checked yet is not "all set" either.
        XCTAssertFalse(SetupChecklist.isComplete(SetupChecklist.checks(inputs { $0.developerMode = nil })))
        XCTAssertFalse(SetupChecklist.isComplete(SetupChecklist.checks(inputs { $0.developerSupport = .trouble })))
        XCTAssertFalse(SetupChecklist.isComplete(SetupChecklist.checks(inputs { $0.engine = .checking })))
        var untrusted = phone
        untrusted.trusted = false
        XCTAssertFalse(SetupChecklist.isComplete(SetupChecklist.checks(inputs { $0.iPhone = untrusted })))
    }

    // MARK: Developer Mode help

    func testTheDeveloperModeRowSaysWhatToDoWhenTheSwitchIsMissing() {
        let r = row("devmode", inputs { $0.developerMode = false })
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.fix, .revealDeveloperMode)
        XCTAssertTrue(r.detail.contains("Show the Switch"), r.detail)
        XCTAssertEqual(SetupCheck.Fix.revealDeveloperMode.label, "Show the Switch")
    }

    // MARK: The iPhone row when the helper is the problem

    func testWithoutTheHelperTheIPhoneRowIsNotAnEndlessSpinner() {
        let r = row("device", inputs { $0.helperInstalled = false; $0.iPhone = nil; $0.hasLookedForDevices = false })
        XCTAssertEqual(r.state, .later)
        XCTAssertTrue(r.detail.contains("helper"), r.detail)
    }

    func testAHelperThatCantListIPhonesIsBlamedNotTheCable() {
        let r = row("device", inputs { $0.iPhone = nil; $0.deviceListError = "No module named 'pymobiledevice3'" })
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.fix, .installHelper)
        XCTAssertTrue(r.detail.contains("No module named"), r.detail)
        XCTAssertFalse(r.detail.contains("data cable"), r.detail)
    }

    func testNoIPhoneAndAHealthyHelperStillSaysPlugItIn() {
        let r = row("device", inputs { $0.iPhone = nil })
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.fix, .connectionHelp)
        XCTAssertTrue(r.detail.contains("data cable"), r.detail)
    }
}
