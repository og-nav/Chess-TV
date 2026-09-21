import Testing
import Foundation
import FollowKit
@testable import ChessTVMobile

@Suite("Registering this install exactly once")
struct RegistrationTests {

    private let credential = DeviceCredential(deviceId: "device-1", installToken: "token-1")

    @Test("A fresh install with a token registers")
    func freshInstall() {
        let decision = RegistrationPlan.decide(
            credential: nil,
            registeredToken: nil,
            registeredEnvironment: nil,
            apnsToken: "abc123",
            environment: "sandbox"
        )
        #expect(decision == .register)
    }

    @Test("Without a token from iOS there is nothing to do but wait")
    func noTokenYet() {
        #expect(
            RegistrationPlan.decide(
                credential: nil,
                registeredToken: nil,
                registeredEnvironment: nil,
                apnsToken: nil,
                environment: "sandbox"
            ) == .waitingForToken
        )
        #expect(
            RegistrationPlan.decide(
                credential: credential,
                registeredToken: "abc123",
                registeredEnvironment: "sandbox",
                apnsToken: "",
                environment: "sandbox"
            ) == .waitingForToken
        )
    }

    @Test("A refreshed token is a PUT, not a second install")
    func tokenRefreshDoesNotDuplicate() {
        let decision = RegistrationPlan.decide(
            credential: credential,
            registeredToken: "old-token",
            registeredEnvironment: "production",
            apnsToken: "new-token",
            environment: "production"
        )
        #expect(decision == .updateToken)
    }

    @Test("Launching again with the same token sends nothing")
    func idempotentLaunch() {
        let decision = RegistrationPlan.decide(
            credential: credential,
            registeredToken: "same-token",
            registeredEnvironment: "production",
            apnsToken: "same-token",
            environment: "production"
        )
        #expect(decision == .upToDate)
    }

    @Test("Crossing between the sandbox and production registers afresh, because a PUT cannot say which")
    func environmentChangeRegistersAgain() {
        let decision = RegistrationPlan.decide(
            credential: credential,
            registeredToken: "same-token",
            registeredEnvironment: "sandbox",
            apnsToken: "same-token",
            environment: "production"
        )
        #expect(decision == .register)
    }

    @Test("Retries back off from five seconds and stop at five minutes")
    func retryBackoff() {
        #expect(RegistrationPlan.retryDelay(afterFailures: 0) == .seconds(5))
        #expect(RegistrationPlan.retryDelay(afterFailures: 1) == .seconds(5))
        #expect(RegistrationPlan.retryDelay(afterFailures: 2) == .seconds(10))
        #expect(RegistrationPlan.retryDelay(afterFailures: 3) == .seconds(20))
        #expect(RegistrationPlan.retryDelay(afterFailures: 20) == .seconds(300))
    }

    @Test("A device token is lowercase hex, two characters a byte")
    func hexToken() {
        let data = Data([0x00, 0x0f, 0xa0, 0xff])
        #expect(RegistrationPlan.hexToken(from: data) == "000fa0ff")
        #expect(RegistrationPlan.hexToken(from: Data()) == "")
    }
}

@Suite("The push server address")
struct ServerURLTests {

    @Test("A bare host becomes https")
    func bareHost() throws {
        let url = try #require(try ServerURL.normalize("chess.example.com").get())
        #expect(url.absoluteString == "https://chess.example.com")
    }

    @Test("An empty field means no server, which is a valid answer")
    func emptyIsNoServer() throws {
        #expect(try ServerURL.normalize("").get() == nil)
        #expect(try ServerURL.normalize("   ").get() == nil)
    }

    @Test("A trailing slash is trimmed so the client's own paths join cleanly")
    func trailingSlash() throws {
        let url = try #require(try ServerURL.normalize("https://chess.example.com/").get())
        #expect(url.absoluteString == "https://chess.example.com")
    }

    @Test("localhost is allowed for a laptop, anything without a dot is not")
    func hosts() {
        #expect((try? ServerURL.normalize("http://localhost:8080").get()) != nil)
        if case .failure(let error) = ServerURL.normalize("notahost") {
            #expect(error == .missingHost)
        } else {
            Issue.record("a host with no dot should be refused")
        }
    }

    @Test("A scheme that is not http or https is refused")
    func schemes() {
        if case .failure(let error) = ServerURL.normalize("ftp://chess.example.com") {
            #expect(error == .badScheme("ftp"))
        } else {
            Issue.record("ftp should be refused")
        }
    }

    @Test("A query or a fragment is refused rather than silently dropped")
    func extras() {
        if case .failure(let error) = ServerURL.normalize("https://chess.example.com?token=secret") {
            #expect(error == .hasPathExtras)
        } else {
            Issue.record("a query should be refused")
        }
    }

    @Test("The row shows the host, with a port when there is one")
    func displayName() throws {
        let plain = try #require(try ServerURL.normalize("https://chess.example.com").get())
        #expect(ServerURL.displayName(for: plain) == "chess.example.com")
        let ported = try #require(try ServerURL.normalize("http://localhost:8080").get())
        #expect(ServerURL.displayName(for: ported) == "localhost:8080")
    }
}

@Suite("Credential scope and explicit local-only configuration")
struct IdentityIsolationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ChessTV.IdentityTests.\(UUID())")!
    }

    @Test("A client bound to the old host never reads the new host's credential")
    func oldClientCannotFollowMutableScope() async throws {
        let preferences = defaults()
        let inner = InMemoryCredentialStore()
        let scope = ScopedCredentialStore(wrapping: inner, scope: "https://one.example", defaults: preferences)
        try await scope.save(DeviceCredential(deviceId: "one", installToken: "one-token"))
        let oldClient = scope.clientStore()
        #expect(try await oldClient.load()?.deviceId == "one")
        scope.setScope("https://two.example")
        try await scope.clear()
        try await scope.save(DeviceCredential(deviceId: "two", installToken: "two-token"))
        #expect(try await oldClient.load() == nil)
        #expect(try await scope.clientStore().load()?.deviceId == "two")
        // A delayed HTTP registration response cannot write through its old client's store.
        try await oldClient.save(DeviceCredential(deviceId: "late-one", installToken: "old-token"))
        #expect(try await scope.load()?.deviceId == "two")
    }

    @Test("Reset invalidates old clients even when the server address stays the same")
    func resetEpoch() async throws {
        let scope = ScopedCredentialStore(wrapping: InMemoryCredentialStore(), scope: "https://one.example", defaults: defaults())
        try await scope.save(DeviceCredential(deviceId: "one", installToken: "one-token"))
        let oldClient = scope.clientStore()
        scope.invalidateIdentity()
        try await scope.clear()
        try await scope.save(DeviceCredential(deviceId: "new", installToken: "new-token"))
        #expect(try await oldClient.load() == nil)
        #expect(try await scope.clientStore().load()?.deviceId == "new")
    }

    @Test("Every install uses the published host, including one upgrading from a cleared field")
    @MainActor func theServiceIsAlwaysConfigured() {
        let preferences = defaults()
        #expect(ServerConfiguration(defaults: preferences).url == ServerConfiguration.defaultURL)
        // An older build wrote an empty string when its Settings field was cleared. There is no
        // longer a screen to clear, so that is read as "never chosen" rather than as a choice:
        // upgrading must not leave a phone silently unable to receive anything.
        preferences.set("", forKey: ServerConfiguration.Key.serverURL)
        #expect(ServerConfiguration(defaults: preferences).url == ServerConfiguration.defaultURL)
        // A URL that was actually stored still wins, which is what keeps the model useful.
        preferences.set("https://private.example.com", forKey: ServerConfiguration.Key.serverURL)
        #expect(ServerConfiguration(defaults: preferences).url == URL(string: "https://private.example.com"))
    }

    @Test("An early APNs callback waits for the saved identity instead of registering twice")
    @MainActor func earlyTokenWaitsForKeychain() async {
        let saved = DeviceCredential(deviceId: "existing", installToken: "existing-token")
        let preferences = defaults()
        preferences.set("010203", forKey: DeviceRegistrar.Key.registeredToken)
        preferences.set(MobileIdentity.apnsEnvironment, forKey: DeviceRegistrar.Key.registeredEnvironment)
        let registrar = DeviceRegistrar(credentials: InMemoryCredentialStore(saved), defaults: preferences, environment: FakePushEnvironment())
        let server = FakeFollowServer()
        registrar.setClient(server)
        registrar.tokenArrived(Data([1, 2, 3]))
        for _ in 0..<20 { await Task.yield() }
        #expect(await server.callCount("register") == 0)
        await registrar.loadCredential()
        #expect(registrar.deviceID == "existing")
        #expect(registrar.status == .registered)
        #expect(await server.callCount("register") == 0)
    }

    @Test("A reset during registration cannot resurrect its completed response")
    @MainActor func resetDuringRegister() async {
        let credentials = InMemoryCredentialStore()
        let registrar = DeviceRegistrar(credentials: credentials, defaults: defaults(), environment: FakePushEnvironment())
        let server = FakeFollowServer()
        await server.onceDuringCall { name in
            guard name == "register" else { return }
            await MainActor.run {
                registrar.setClient(nil)
                registrar.reset()
            }
        }
        await registrar.loadCredential()
        registrar.setClient(server)
        registrar.tokenArrived(Data([1, 2, 3]))
        for _ in 0..<100 { await Task.yield() }
        #expect(registrar.deviceID == nil)
        #expect((try? await credentials.load()) == nil)
    }
}

import UserNotifications

@Suite("Repairing push registration")
struct PushRepairTests {
    @Test("Repair waits for a new APNs callback, even when iOS returns the same token")
    @MainActor func waitsForFreshCallback() async {
        let preferences = UserDefaults(suiteName: "ChessTV.PushRepair.\(UUID())")!
        let environment = FakePushEnvironment()
        environment.authorization = .authorized
        let registrar = DeviceRegistrar(credentials: InMemoryCredentialStore(), defaults: preferences, environment: environment)
        let server = FakeFollowServer()
        registrar.setClient(server)
        await registrar.loadCredential()
        registrar.tokenArrived(Data([1, 2, 3]))
        #expect(await registrar.awaitRegistration(timeout: .seconds(2)) == .registered)
        #expect(await server.callCount("register") == 1)

        let repair = Task { await registrar.resetPushRegistration() }
        for _ in 0..<100 where environment.tokenRequests == 0 { await Task.yield() }
        #expect(environment.tokenRequests == 1)
        #expect(registrar.status == .waitingForToken)
        #expect(await server.callCount("register") == 1)
        registrar.tokenArrived(Data([1, 2, 3]))
        #expect(await repair.value == .registered)
        #expect(await server.callCount("register") == 2)
    }

    @Test("Denied permission preserves the identity and does not claim successful repair")
    @MainActor func deniedPermission() async {
        let saved = DeviceCredential(deviceId: "existing", installToken: "existing-token")
        let credentials = InMemoryCredentialStore(saved)
        let environment = FakePushEnvironment()
        let registrar = DeviceRegistrar(credentials: credentials,
            defaults: UserDefaults(suiteName: "ChessTV.PushRepair.\(UUID())")!, environment: environment)
        let server = FakeFollowServer()
        registrar.setClient(server)
        await registrar.loadCredential()
        #expect(await registrar.resetPushRegistration() == .idle)
        #expect(registrar.permission == .denied)
        #expect(registrar.deviceID == saved.deviceId)
        #expect((try? await credentials.load()) == saved)
        #expect(environment.tokenRequests == 0)
        #expect(await server.callCount("register") == 0)
    }
}

@MainActor
private final class FakePushEnvironment: PushEnvironment {
    var authorization: UNAuthorizationStatus = .denied
    var tokenRequests = 0
    func authorizationStatus() async -> UNAuthorizationStatus { authorization }
    func requestAuthorization() async throws -> Bool { false }
    func registerForRemoteNotifications() { tokenRequests += 1 }
    func openSettings() {}
}
