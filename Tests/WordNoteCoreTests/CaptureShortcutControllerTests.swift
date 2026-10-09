import XCTest
@testable import WordNoteCore

@MainActor
final class CaptureShortcutControllerTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "WordNote-Shortcut-Tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: CommandShortcutPreference.storageKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testEnabledDefaultRegistersOnceAndHeldKeyDoesNotRepeatedlyToggle() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        controller.start()
        XCTAssertEqual(backend.events, ["register:1"])
        XCTAssertEqual(controller.activeShortcut?.title, "Control + Shift + Space")
        XCTAssertEqual(controller.activeShortcut?.modifiers, [.control, .shift])
        backend.send(1, true); backend.send(1, true); backend.send(1, true)
        XCTAssertEqual(calls, 1)
        backend.send(1, false); backend.send(1, true)
        XCTAssertEqual(calls, 2)
    }

    func testFreshPreferenceLeavesCommandsDisabledWithoutRegistering() {
        defaults.removeObject(forKey: CommandShortcutPreference.storageKey)
        XCTAssertFalse(CommandShortcutPreference.defaultValue)
        XCTAssertFalse(CommandShortcutPreference.isEnabled(in: defaults))
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.start()
        controller.start()
        XCTAssertFalse(controller.commandShortcutsEnabled)
        XCTAssertNil(controller.activeShortcut)
        XCTAssertTrue(backend.events.isEmpty)
    }

    func testOldGlobalPreferenceDoesNotOptInToNewMasterSwitch() throws {
        defaults.removeObject(forKey: CommandShortcutPreference.storageKey)
        let saved = CaptureShortcutConfiguration(shortcut: .init(key: .f12, modifiers: [.control, .command]))
        let data = try JSONEncoder().encode(saved)
        defaults.set(data, forKey: CaptureShortcutController.storageKey)
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.start()
        XCTAssertEqual(controller.configuration, saved)
        XCTAssertEqual(defaults.data(forKey: CaptureShortcutController.storageKey), data)
        XCTAssertFalse(controller.commandShortcutsEnabled)
        XCTAssertTrue(backend.events.isEmpty)
    }

    func testMasterOffReleasesRegistrationAndOnRestoresSavedChoice() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        backend.send(1, true)
        controller.setCommandShortcutsEnabled(false)
        backend.send(1, true)
        controller.start()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(controller.activeShortcut)
        XCTAssertEqual(backend.events, ["register:1", "unregister:1"])
        controller.setCommandShortcutsEnabled(true)
        controller.setCommandShortcutsEnabled(true)
        backend.send(1, true)
        backend.send(2, true)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(backend.events, ["register:1", "unregister:1", "register:2"])
    }

    func testMaintenanceAndMasterSwitchCannotReenableEachOther() {
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.start()
        controller.setAvailable(false)
        controller.setCommandShortcutsEnabled(false)
        controller.setAvailable(true)
        XCTAssertNil(controller.activeShortcut)
        controller.setAvailable(false)
        controller.setCommandShortcutsEnabled(true)
        XCTAssertNil(controller.activeShortcut)
        XCTAssertEqual(backend.events, ["register:1", "unregister:1"])
        controller.setAvailable(true)
        XCTAssertEqual(controller.activeShortcut, .init())
    }

    func testDraftCanBeSavedWithMasterOffAndEnableChecksConflicts() {
        defaults.set(false, forKey: CommandShortcutPreference.storageKey)
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        let choice = CaptureShortcutConfiguration(shortcut: .init(key: .f12))
        controller.apply(choice)
        XCTAssertEqual(controller.configuration, choice)
        XCTAssertNotNil(defaults.data(forKey: CaptureShortcutController.storageKey))
        XCTAssertTrue(backend.events.isEmpty)
        backend.registrationError = .systemReserved
        controller.setCommandShortcutsEnabled(true)
        XCTAssertNil(controller.activeShortcut)
        XCTAssertEqual(controller.error as? CaptureShortcutError, .systemReserved)
        XCTAssertEqual(controller.configuration, choice)
    }

    func testMasterPreferenceSurvivesRestartAndIndividualDisableIsPreserved() {
        for enabled in [false, true] {
            defaults.set(enabled, forKey: CommandShortcutPreference.storageKey)
            let controller = CaptureShortcutController(backend: Backend(), defaults: defaults) {}
            XCTAssertEqual(controller.commandShortcutsEnabled, enabled)
        }
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.apply(.init(enabled: false))
        controller.setCommandShortcutsEnabled(false)
        controller.setCommandShortcutsEnabled(true)
        XCTAssertFalse(controller.configuration.enabled)
        XCTAssertTrue(backend.events.isEmpty)
    }

    func testFailedReleaseStillStopsCommandCallbacksImmediately() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        backend.failingRemovals = [1]
        controller.setCommandShortcutsEnabled(false)
        backend.send(1, true)
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(controller.error)
        backend.failingRemovals = []
        controller.stop()
    }

    func testRebindingRegistersNewBeforeReleasingOldAndIgnoresOldCallbacks() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        let replacement = CaptureShortcutConfiguration(shortcut: .init(key: .q, modifiers: [.command, .shift]))
        controller.apply(replacement)
        XCTAssertEqual(backend.events, ["register:1", "register:2", "unregister:1"])
        XCTAssertEqual(controller.configuration, replacement)
        backend.send(1, true)
        XCTAssertEqual(calls, 0)
        backend.send(2, true)
        XCTAssertEqual(calls, 1)
    }

    func testConflictRetainsWorkingKeyAndDoesNotPersistFailedChoice() throws {
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.apply(.init())
        let saved = defaults.data(forKey: CaptureShortcutController.storageKey)
        backend.registrationError = .registrationFailed(-9878)
        controller.apply(.init(shortcut: .init(key: .f1)))
        XCTAssertEqual(controller.activeShortcut, .init())
        XCTAssertEqual(controller.configuration, .init())
        XCTAssertEqual(defaults.data(forKey: CaptureShortcutController.storageKey), saved)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(backend.events.contains("unregister:1"))
        XCTAssertEqual(controller.error as? CaptureShortcutError, .registrationFailed(-9878))
        backend.registrationError = nil
        controller.apply(.init(shortcut: .init(key: .f1)))
        XCTAssertEqual(controller.activeShortcut?.key, .f1)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.error)
    }

    func testStartupConflictCanRetryWithoutChangingPreference() {
        let backend = Backend()
        backend.registrationError = .systemReserved
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.start()
        XCTAssertNil(controller.activeShortcut)
        XCTAssertTrue(controller.configuration.enabled)
        XCTAssertNotNil(controller.errorMessage)
        backend.registrationError = nil
        controller.start()
        XCTAssertNotNil(controller.activeShortcut)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisableReleasesKeyAndPersistsAcrossNewController() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        controller.apply(.init(enabled: false))
        backend.send(1, true)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.activeShortcut)
        let nextBackend = Backend()
        let next = CaptureShortcutController(backend: nextBackend, defaults: defaults) {}
        next.start()
        XCTAssertFalse(next.configuration.enabled)
        XCTAssertTrue(nextBackend.events.isEmpty)
    }

    func testStoredChoiceRestoresWithoutExposingAnyVocabulary() {
        let controller = CaptureShortcutController(backend: Backend(), defaults: defaults) {}
        let choice = CaptureShortcutConfiguration(shortcut: .init(key: .f12, modifiers: [.control, .command]))
        controller.apply(choice)
        let next = CaptureShortcutController(backend: Backend(), defaults: defaults) {}
        XCTAssertEqual(next.configuration, choice)
        next.start()
        XCTAssertEqual(next.activeShortcut, choice.shortcut)
    }

    func testSavedOldDefaultIsNotSilentlyReplacedEvenWhenItConflicts() throws {
        let oldChoice = CaptureShortcutConfiguration(shortcut: .init(key: .space, modifiers: [.control, .option]))
        let encoded = try JSONEncoder().encode(oldChoice)
        defaults.set(encoded, forKey: CaptureShortcutController.storageKey)
        let backend = Backend()
        backend.registrationError = .systemReserved
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.start()
        XCTAssertEqual(controller.configuration, oldChoice)
        XCTAssertEqual(defaults.data(forKey: CaptureShortcutController.storageKey), encoded)
        XCTAssertEqual(controller.error as? CaptureShortcutError, .systemReserved)
        XCTAssertNil(controller.activeShortcut)

        backend.registrationError = nil
        controller.apply(.init())
        XCTAssertEqual(controller.activeShortcut, CaptureShortcut(key: .space, modifiers: [.control, .shift]))
        XCTAssertEqual(try JSONDecoder().decode(CaptureShortcutConfiguration.self,
                                               from: XCTUnwrap(defaults.data(forKey: CaptureShortcutController.storageKey))), .init())
    }

    func testCorruptOrUnknownStoredValueFailsClosedWithoutOverwritingIt() {
        for value: Any in ["invalid", Data("bad JSON".utf8), Data(#"{"enabled":true,"shortcut":{"key":"future-key","modifiers":{"rawValue":3}}}"#.utf8)] {
            defaults.set(value, forKey: CaptureShortcutController.storageKey)
            let backend = Backend()
            let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
            controller.start()
            XCTAssertFalse(controller.configuration.enabled)
            XCTAssertNotNil(controller.errorMessage)
            XCTAssertTrue(backend.events.isEmpty)
            XCTAssertNotNil(defaults.object(forKey: CaptureShortcutController.storageKey))
        }
    }

    func testInvalidCombinationsDoNotRegisterButDisabledDraftCanHaveFewerModifiers() {
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        for modifiers: CaptureShortcut.Modifiers in [[], [.shift], [.option, .shift], .init(rawValue: 255)] {
            controller.apply(.init(shortcut: .init(modifiers: modifiers)))
            XCTAssertNotNil(controller.errorMessage)
            XCTAssertTrue(backend.events.isEmpty)
        }
        controller.apply(.init(enabled: false, shortcut: .init(modifiers: [])))
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.configuration.enabled)
    }

    func testMaintenanceUnregistersAndRestoresTheSavedChoiceWithoutChangingIt() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        backend.send(1, true)
        controller.setAvailable(false)
        backend.send(1, false); backend.send(1, true)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(controller.activeShortcut)
        let changed = CaptureShortcutConfiguration(shortcut: .init(key: .b))
        controller.apply(changed)
        XCTAssertEqual(backend.events, ["register:1", "unregister:1"])
        controller.setAvailable(true)
        XCTAssertEqual(controller.activeShortcut, changed.shortcut)
        backend.send(2, true)
        XCTAssertEqual(calls, 2)
    }

    func testFailedOldRemovalRollsBackNewRegistrationAndKeepsOldConfiguration() {
        let backend = Backend()
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) {}
        controller.start()
        backend.failingRemovals = [1]
        controller.apply(.init(shortcut: .init(key: .g)))
        XCTAssertEqual(backend.events, ["register:1", "register:2", "unregister:1", "unregister:2"])
        XCTAssertEqual(controller.activeShortcut, .init())
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(defaults.data(forKey: CaptureShortcutController.storageKey))
        XCTAssertEqual(controller.error as? CaptureShortcutError, .removalFailed(-50))
    }

    func testFailedCleanupIsRetriedAndInactiveRegistrationNeverFires() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        backend.failingRemovals = [1, 2]
        controller.apply(.init(shortcut: .init(key: .g)))
        backend.send(2, true)
        XCTAssertEqual(calls, 0)
        backend.failingRemovals = []
        controller.apply(.init(shortcut: .init(key: .b)))
        XCTAssertEqual(Array(backend.events.suffix(3)), ["unregister:2", "register:3", "unregister:1"])
        backend.send(3, true)
        XCTAssertEqual(calls, 1)
    }

    func testStopMakesLateCallbacksInertEvenWhenSystemReleaseFails() {
        let backend = Backend()
        var calls = 0
        let controller = CaptureShortcutController(backend: backend, defaults: defaults) { calls += 1 }
        controller.start()
        backend.failingRemovals = [1]
        controller.stop()
        backend.send(1, true)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertNotNil(controller.errorMessage)
        backend.failingRemovals = []
        controller.stop()
        XCTAssertNil(controller.activeShortcut)
    }

    private final class Backend: CaptureShortcutBackend {
        var events: [String] = []
        var callbacks: [UInt32: @MainActor (Bool) -> Void] = [:]
        var registrationError: CaptureShortcutError?
        var failingRemovals = Set<UInt32>()
        func register(_ shortcut: CaptureShortcut, id: UInt32, onKey: @escaping @MainActor (Bool) -> Void) throws {
            events.append("register:\(id)")
            if let registrationError { throw registrationError }
            callbacks[id] = onKey
        }
        func unregister(_ id: UInt32) throws {
            events.append("unregister:\(id)")
            if failingRemovals.contains(id) { throw CaptureShortcutError.removalFailed(-50) }
        }
        func send(_ id: UInt32, _ pressed: Bool) { callbacks[id]?(pressed) }
    }
}
