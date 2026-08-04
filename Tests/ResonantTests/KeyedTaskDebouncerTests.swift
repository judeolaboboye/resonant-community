import Testing
@testable import Resonant

@MainActor
struct KeyedTaskDebouncerTests {
    @Test
    func reschedulingSameKeyKeepsOnlyLatestOperation() async throws {
        let debouncer = KeyedTaskDebouncer<String>()
        let recorder = ExecutionRecorder()

        debouncer.schedule(key: "journal", delay: .milliseconds(50)) {
            await recorder.record("first")
        }
        debouncer.schedule(key: "journal", delay: .milliseconds(50)) {
            await recorder.record("second")
        }

        try await Task.sleep(for: .milliseconds(500))

        withExtendedLifetime(debouncer) {}
        let values = await recorder.values
        #expect(values == ["second"])
    }

    @Test
    func distinctKeysRunIndependently() async throws {
        let debouncer = KeyedTaskDebouncer<String>()
        let recorder = ExecutionRecorder()

        debouncer.schedule(key: "journal", delay: .milliseconds(30)) {
            await recorder.record("journal")
        }
        debouncer.schedule(key: "memo", delay: .milliseconds(30)) {
            await recorder.record("memo")
        }

        try await Task.sleep(for: .milliseconds(500))

        withExtendedLifetime(debouncer) {}
        let values = await recorder.values.sorted()
        #expect(values == ["journal", "memo"])
    }
}

private actor ExecutionRecorder {
    private var storage: [String] = []

    func record(_ value: String) {
        storage.append(value)
    }

    var values: [String] {
        storage
    }
}
