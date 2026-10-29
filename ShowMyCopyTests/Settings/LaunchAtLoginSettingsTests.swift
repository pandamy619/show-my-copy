import Testing

@testable import ShowMyCopy

/// Settings → General → Open at login, against a fake of the system's login item.
@MainActor
struct LaunchAtLoginSettingsTests {
    private let service = FakeLoginItem()

    /// A model whose status was read once, as when Settings open.
    private func openedSettings(status: LoginItemStatus = .notRegistered) async -> LaunchAtLoginSettings {
        service.currentStatus = status
        let settings = LaunchAtLoginSettings(service: service)
        await settings.settingsOpened()
        return settings
    }

    // MARK: Reading the status

    @Test func isUnknownAndCannotChangeUntilTheStatusIsRead() async {
        let settings = LaunchAtLoginSettings(service: service)
        #expect(settings.status == nil)
        #expect(!settings.isOn)
        #expect(!settings.canChange)
        #expect(service.statusReads == 0)

        await settings.setOn(true)
        #expect(service.registerCount == 0)
    }

    @Test(arguments: [
        (LoginItemStatus.notRegistered, false, false),
        (.enabled, true, false),
        (.requiresApproval, true, true),
        (.notFound, false, false),
    ])
    func showsWhatTheSystemSays(status: LoginItemStatus, isOn: Bool, needsApproval: Bool) async {
        let settings = await openedSettings(status: status)
        #expect(settings.status == status)
        #expect(settings.isOn == isOn)
        #expect(settings.needsApproval == needsApproval)
        #expect(settings.canChange)
        #expect(settings.problem == nil)
    }

    @Test func readsTheSystemAgainEachTimeSettingsOpen() async {
        let settings = await openedSettings(status: .enabled)

        // The user turns the app off in System Settings → General → Login Items.
        service.currentStatus = .notRegistered
        settings.settingsClosed()
        await settings.settingsOpened()

        #expect(!settings.isOn)
        #expect(service.statusReads == 2)
    }

    @Test func refreshPicksUpAnApprovalGivenInSystemSettings() async {
        let settings = await openedSettings(status: .requiresApproval)

        service.currentStatus = .enabled
        await settings.refresh()

        #expect(settings.isOn)
        #expect(!settings.needsApproval)
    }

    // MARK: Changing it

    @Test func isOffAndNeverRegistersByItself() async {
        let settings = await openedSettings()
        await settings.refresh()
        settings.suggestOnce()

        #expect(!settings.isOn)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @Test func turningOnRegistersTheApp() async {
        let settings = await openedSettings()

        await settings.setOn(true)

        #expect(service.registerCount == 1)
        #expect(settings.isOn)
        #expect(settings.status == .enabled)
        #expect(settings.problem == nil)
        #expect(settings.canChange)
    }

    @Test func turningOffUnregistersTheApp() async {
        let settings = await openedSettings(status: .enabled)

        await settings.setOn(false)

        #expect(service.unregisterCount == 1)
        #expect(!settings.isOn)
        #expect(settings.problem == nil)
    }

    @Test func turningOffAnAppWaitingForApprovalUnregistersIt() async {
        let settings = await openedSettings(status: .requiresApproval)

        await settings.setOn(false)

        #expect(service.unregisterCount == 1)
        #expect(!settings.isOn)
        #expect(!settings.needsApproval)
    }

    @Test func turningOnFromNotFoundRegistersTheApp() async {
        let settings = await openedSettings(status: .notFound)

        await settings.setOn(true)

        #expect(service.registerCount == 1)
        #expect(settings.isOn)
    }

    @Test func askingForTheStateItIsInDoesNothing() async {
        let settings = await openedSettings(status: .enabled)

        await settings.setOn(true)
        #expect(service.registerCount == 0)

        service.currentStatus = .notRegistered
        await settings.refresh()
        await settings.setOn(false)
        #expect(service.unregisterCount == 0)
    }

    @Test func turningOnThatNeedsApprovalShowsTheNoteAndNoProblem() async {
        service.statusAfterRegister = .requiresApproval
        let settings = await openedSettings()

        await settings.setOn(true)

        #expect(settings.isOn)
        #expect(settings.needsApproval)
        #expect(settings.problem == nil)
    }

    @Test func openLoginItemsOpensSystemSettings() async {
        let settings = await openedSettings(status: .requiresApproval)

        settings.openLoginItems()

        #expect(service.openSystemSettingsCount == 1)
    }

    // MARK: Failures

    @Test func aFailedTurnOnShowsAProblemAndStaysOff() async {
        service.registerFails = true
        let settings = await openedSettings()

        await settings.setOn(true)

        #expect(settings.problem == .couldNotTurnOn)
        #expect(!settings.isOn)
        #expect(settings.canChange)
    }

    @Test func aFailedTurnOffShowsAProblemAndStaysOn() async {
        service.unregisterFails = true
        let settings = await openedSettings(status: .enabled)

        await settings.setOn(false)

        #expect(settings.problem == .couldNotTurnOff)
        #expect(settings.isOn)
    }

    /// macOS refuses to register an app the user turned off in Login Items and wants approval instead. The note
    /// says what to do; an error would not.
    @Test func aRefusedTurnOnThatWaitsForApprovalShowsTheNoteInsteadOfAProblem() async {
        service.registerFails = true
        let settings = await openedSettings()
        service.currentStatus = .requiresApproval

        await settings.setOn(true)

        #expect(settings.problem == nil)
        #expect(settings.needsApproval)
    }

    /// For example "not registered" when the user removed the app in System Settings while Settings were open.
    @Test func aFailedChangeThatStillEndsInTheStateAskedForShowsNoProblem() async {
        service.unregisterFails = true
        let settings = await openedSettings(status: .enabled)
        service.currentStatus = .notRegistered

        await settings.setOn(false)

        #expect(settings.problem == nil)
        #expect(!settings.isOn)
    }

    @Test func aSuccessfulChangeClearsAnEarlierProblem() async {
        service.registerFails = true
        let settings = await openedSettings()
        await settings.setOn(true)
        #expect(settings.problem == .couldNotTurnOn)

        service.registerFails = false
        await settings.setOn(true)

        #expect(settings.problem == nil)
        #expect(settings.isOn)
    }

    @Test func openingSettingsAgainClearsAnEarlierProblem() async {
        service.registerFails = true
        let settings = await openedSettings()
        await settings.setOn(true)

        settings.settingsClosed()
        #expect(settings.problem == nil)
        await settings.setOn(true)
        #expect(settings.problem == .couldNotTurnOn)
        await settings.settingsOpened()
        #expect(settings.problem == nil)
    }

    // MARK: Changes in flight

    @Test func waitsForAChangeBeforeTakingAnother() async {
        let settings = await openedSettings()
        service.changeGate.arm()

        let change = Task { await settings.setOn(true) }
        await service.changeGate.waitUntilReached()
        #expect(settings.isChanging)
        #expect(!settings.canChange)
        await settings.setOn(true)
        await settings.setOn(false)
        // A read while the change is under way would show the state before it: the change reads when done.
        await settings.refresh()
        service.changeGate.open()
        await change.value

        #expect(service.registerCount == 1)
        #expect(service.unregisterCount == 0)
        #expect(service.statusReads == 2)
        #expect(!settings.isChanging)
        #expect(settings.isOn)
    }

    @Test func aReadThatStartedBeforeAChangeDoesNotUndoIt() async {
        let settings = await openedSettings()
        service.statusGate.arm()

        // The read gets "not registered" and is held before it reports it.
        let read = Task { await settings.refresh() }
        await service.statusGate.waitUntilReached()
        await settings.setOn(true)
        service.statusGate.open()
        await read.value

        #expect(settings.isOn)
        #expect(settings.status == .enabled)
    }

    // MARK: The first launch's suggestion

    @Test func suggestsTurningOnOnlyWhenAskedTo() async {
        let settings = await openedSettings()
        #expect(!settings.showsSuggestion)

        settings.suggestOnce()

        #expect(settings.showsSuggestion)
    }

    @Test func doesNotSuggestBeforeTheStatusIsKnownOrOnceItIsOn() async {
        let unread = LaunchAtLoginSettings(service: service)
        unread.suggestOnce()
        #expect(!unread.showsSuggestion)

        let settings = await openedSettings(status: .enabled)
        settings.suggestOnce()
        #expect(!settings.showsSuggestion)
    }

    @Test func theSuggestionHidesOnceTurnedOn() async {
        let settings = await openedSettings()
        settings.suggestOnce()

        await settings.setOn(true)

        #expect(!settings.showsSuggestion)
    }

    @Test func theSuggestionIsGoneAfterSettingsClose() async {
        let settings = await openedSettings()
        settings.suggestOnce()

        settings.settingsClosed()
        await settings.settingsOpened()

        #expect(!settings.suggestsTurningOn)
        #expect(!settings.showsSuggestion)
    }
}
