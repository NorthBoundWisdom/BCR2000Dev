#if os(macOS)
    import XCTest
    import Foundation
    import Darwin
    @testable import BCRAgentConsole
    import BCRFoundation
    import BCRPersistenceAdapter
    import BCRSurfaceDomain
    import BCRProviderMCPAdapter

    @MainActor
    final class GUIVirtualSurfaceTests: XCTestCase {
        private func context(_ capacity: Int? = nil) throws -> (GUIVirtualContext, Task<Data, Never>) {
            var tokenFD = [Int32](repeating: -1, count: 2), readyFD = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(pipe(&tokenFD), 0); XCTAssertEqual(pipe(&readyFD), 0)
            let token = Data(String(repeating: "a", count: 64).utf8)
            _ = token.withUnsafeBytes { write(tokenFD[1], $0.baseAddress, $0.count) }; close(tokenFD[1])
            let context = try GUIVirtualContext(.init(
                tokenFD: tokenFD[0],
                readyFD: readyFD[1],
                port: 0,
                inputCapacity: capacity
            ))
            let reader = Task.detached { () -> Data in
                let file = FileHandle(fileDescriptor: readyFD[0], closeOnDealloc: true)
                return (try? file.readToEnd()) ?? Data()
            }
            return (context, reader)
        }

        private func model(_ context: GUIVirtualContext) -> ConsoleViewModel {
            .init(stores: context.stores, startsMIDI: false, runtimeMode: .guiVirtual(context),
                  initialPreset: .robotArm, automaticallyAdvancesMock: false, timing: .immediate)
        }

        func testArgumentModeIsPureExplicitAndRejectsConflictsBeforeOwners() throws {
            XCTAssertNil(try GUIVirtualOptions.parse(["app"]))
            let valid = [
                "app",
                "--gui-virtual-surface",
                "--gui-virtual-surface-token-fd",
                "9",
                "--gui-virtual-surface-ready-fd",
                "10"
            ]
            XCTAssertEqual(try GUIVirtualOptions.parse(valid)?.port, 0)
            for tail in [
                ["--gui-virtual-surface"],
                ["--mcp-token-stdin"],
                ["--integration-test"],
                ["--owned-virtual-rehearsal"],
                ["--surface-input-event-capacity", "65537"]
            ] {
                XCTAssertThrowsError(try GUIVirtualOptions.parse(valid + tail))
            }
            XCTAssertThrowsError(try GUIVirtualOptions.parse(["app", "--surface-input-event-capacity", "1"]))
        }

        func testGUIOwnsTheSameSessionAndProfilesBothDeclaredCapacityCombinations() async throws {
            for capacity: Int? in [nil, 4] {
                let (context, reader) = try context(capacity), baseline = ConsoleConstructionAudit.counts
                let model = model(context), controller = try XCTUnwrap(model.deviceWork.guiVirtualSurface)
                XCTAssertTrue(controller.surface === model.deviceWork.session)
                XCTAssertFalse(controller.surface.permitsHardwareSource)
                let discovery = controller.gateway.call("surface_control_discover").value
                XCTAssertEqual(discovery.value(for: "source"), .string("simulation"))
                XCTAssertEqual(discovery.value(for: "profile")?.value(for: "id"), .string("bcr2000.gui.virtual"))
                XCTAssertEqual(discovery.value(for: "profile")?.value(for: "version"), .string("1"))
                XCTAssertEqual(discovery.value(for: "contract_version"), .string(capacity == nil ? "1.3" : "1.5"))
                XCTAssertEqual(controller.gateway.toolDefinitions.count, capacity == nil ? 7 : 8)
                XCTAssertFalse(discovery.value(for: "profile")!.value(for: "capabilities")!.arrayValue!
                    .contains(.string("input.hold")))
                var changed = model.configuration
                changed.name += " changed interpretation"
                try model.deviceWork.session.replaceConfiguration(changed, persist: false)
                let next = controller.gateway.call("surface_control_discover").value
                XCTAssertEqual(
                    next.value(for: "profile")?.value(for: "id"),
                    discovery.value(for: "profile")?.value(for: "id")
                )
                XCTAssertEqual(next.value(for: "contract_version"), discovery.value(for: "contract_version"))
                XCTAssertNotEqual(
                    next.value(for: "expected")?.value(for: "epoch"),
                    discovery.value(for: "expected")?.value(for: "epoch")
                )
                XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
                let failures = await controller.finish(); XCTAssertTrue(failures.isEmpty)
                let data = await reader.value
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(String(repeating: "a", count: 64)))
            }
        }

        func testRealInterfaceIntentIsObservedAndFeedbackOnlyChangesActualMockDisplay() async throws {
            let (context, reader) = try context()
            let model = model(context), controller = try XCTUnwrap(model.deviceWork.guiVirtualSurface)
            let control = BCRControlID.pushEncoder(group: 1, 1)
            model.turn(control, by: 2)
            let parameters = model.engine.parameterValues
            let before = controller.gateway.call(
                "surface_control_snapshot",
                arguments: .object(["instance_id": .string(controller.gateway.call("surface_control_discover").value
                        .value(for: "expected")!.value(for: "instance_id")!.stringValue!)])
            ).value
            XCTAssertEqual(before.value(for: "latest_input_sequence"), .string("1"))
            let discovery = controller.gateway.call("surface_control_discover").value
            let reply = controller.gateway.call("surface_control_feedback", arguments: .object([
                "expected": discovery.value(for: "expected")!, "control_id": .string("pushEncoder.1.1"),
                "kind": .string("value"), "value": .number(64)
            ]))
            XCTAssertFalse(reply.isError)
            XCTAssertEqual(model.displayValue(of: control), 64)
            XCTAssertEqual(model.engine.parameterValues, parameters)
            let after = controller.gateway.call(
                "surface_control_snapshot",
                arguments: .object(["instance_id": discovery.value(for: "expected")!.value(for: "instance_id")!])
            ).value
            XCTAssertEqual(after.value(for: "inputs"), before.value(for: "inputs"))
            XCTAssertEqual(after.value(for: "latest_input_sequence"), before.value(for: "latest_input_sequence"))
            for tool in ["set_parameter", "set_source", "set_midi_endpoints"] {
                XCTAssertTrue(controller.gateway.call(tool).isError)
            }
            let failures = await controller.finish(); XCTAssertTrue(failures.isEmpty); _ = await reader.value
        }

        func testAllHardwareEntryPathsRejectBeforeStoreOrFactoryAndStayMock() async throws {
            for action in 0 ..< 7 {
                let (context, reader) = try context(), baseline = ConsoleConstructionAudit.counts
                let model = model(context), controller = try XCTUnwrap(model.deviceWork.guiVirtualSurface)
                switch action {
                case 0: model.selectSource(.hardware)
                case 1: model.deviceWork.session.selectSource(.hardware)
                case 2: XCTAssertThrowsError(try model.deviceWork.session.adoptHardwareSnapshot([]))
                case 3: XCTAssertThrowsError(try model.deviceWork.commitEndpointSelection(.init()))
                case 4: model.deviceWork.connectionWork.start()
                case 5: model.deviceWork.presetWork.beginPresetAlignment()
                default: model.deviceWork.recoveryWork.restorePresetBeforeAlignment()
                }
                XCTAssertEqual(model.source, .mock)
                XCTAssertFalse(model.deviceWork.session.connection.isConnected)
                XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
                XCTAssertFalse(FileManager.default
                    .fileExists(atPath: context.directory.appending(path: "midi-endpoints.json").path))
                _ = await controller.finish(); _ = await reader.value
            }
        }

        func testLegacyMCPAndExternalOutputCannotRestoreStartOrReadCredential() async throws {
            let (context, reader) = try context(), baseline = ConsoleConstructionAudit.counts
            var settings = MCPSettings(); settings.enabled = true
            try JSONFileStore<MCPSettings>(fileURL: context.directory.appending(path: "mcp-settings.json"))
                .save(settings)
            let model = model(context), controller = try XCTUnwrap(model.deviceWork.guiVirtualSurface)
            await model.mcp.restore(); await model.mcp.setEnabled(true); await model.mcp.copyToken()
            model.output.restore(); model.output.start()
            XCTAssertFalse(model.mcp.isListening); XCTAssertFalse(model.mcp.settings.enabled)
            XCTAssertFalse(model.output.settings.enabled)
            XCTAssertEqual(context.legacyCredential.attempts, 0)
            XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
            let failures = await controller.finish(); XCTAssertTrue(failures.isEmpty); _ = await reader.value
        }

        func testMalformedCredentialPipesFailBeforeModelAndCloseTransferredEnds() throws {
            let baseline = ConsoleConstructionAudit.counts
            for payload in [String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                            String(repeating: "A", count: 64)]
            {
                var token = [Int32](repeating: -1, count: 2), ready = [Int32](repeating: -1, count: 2)
                XCTAssertEqual(pipe(&token), 0); XCTAssertEqual(pipe(&ready), 0)
                let data = Data(payload.utf8)
                _ = data.withUnsafeBytes { write(token[1], $0.baseAddress, $0.count) }; close(token[1])
                XCTAssertThrowsError(try GUIVirtualContext(.init(
                    tokenFD: token[0],
                    readyFD: ready[1],
                    port: 0,
                    inputCapacity: nil
                )))
                XCTAssertEqual(fcntl(token[0], F_GETFD), -1)
                XCTAssertEqual(fcntl(ready[1], F_GETFD), -1)
                close(ready[0])
                XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
            }
            var token = [Int32](repeating: -1, count: 2), ready = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(pipe(&token), 0); XCTAssertEqual(pipe(&ready), 0)
            defer { for fd in token + ready { close(fd) } }
            XCTAssertThrowsError(try GUIVirtualContext(.init(
                tokenFD: token[1],
                readyFD: ready[0],
                port: 0,
                inputCapacity: nil
            )))
            XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
        }

        func testPermanentDriverRejectsDirectCallsAndShutdownIsIdempotent() async throws {
            let (context, reader) = try context(), baseline = ConsoleConstructionAudit.counts
            let model = model(context), controller = try XCTUnwrap(model.deviceWork.guiVirtualSurface)
            XCTAssertThrowsError(try context.midi.start())
            context.midi.beginStartup(); context.midi.selectEndpoints(.init())
            XCTAssertThrowsError(try context.midi.send(.controlChange(channel: 0, number: 1, value: 1)))
            do { _ = try await context.midi.readSnapshot(expected: []); XCTFail("Read unexpectedly succeeded")
            } catch {}
            do { _ = try await context.midi.readCurrentPreset(); XCTFail("Read unexpectedly succeeded") } catch {}
            do { _ = try await context.midi.readMemoryPreset(1); XCTFail("Read unexpectedly succeeded") } catch {}
            do { _ = try await context.midi.readPresetNames(); XCTFail("Read unexpectedly succeeded") } catch {}
            do { try await context.midi.sendPresetFrames([], progress: { _ in
            }); XCTFail("Write unexpectedly succeeded") } catch {}
            XCTAssertEqual(model.source, .mock)
            XCTAssertFalse(context.midi.connection.isConnected)
            XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
            let first = await controller.finish(), second = await controller.finish()
            XCTAssertEqual(first, second); XCTAssertTrue(first.isEmpty)
            let finalData = await reader.value
            let final = try XCTUnwrap(String(data: finalData, encoding: .utf8))
            XCTAssertTrue(final.contains("midi_start"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        }

        func testOwnedDirectoryReplacementIsVisibleAndNeverDeleted() async throws {
            let (context, reader) = try context()
            let model = model(context), controller = try XCTUnwrap(model.deviceWork.guiVirtualSurface)
            let held = context.directory.appendingPathExtension("held")
            try FileManager.default.moveItem(at: context.directory, to: held)
            try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: false)
            defer {
                try? FileManager.default.removeItem(at: held)
                try? FileManager.default.removeItem(at: context.directory)
            }
            let failures = await controller.finish()
            XCTAssertTrue(failures.contains("owned_directory_unconfirmed"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: context.directory.path))
            _ = await reader.value
        }

        func testCredentialWithoutEOFIsBoundedAndRegularFilesAreRefused() throws {
            let baseline = ConsoleConstructionAudit.counts
            var token = [Int32](repeating: -1, count: 2), ready = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(pipe(&token), 0); XCTAssertEqual(pipe(&ready), 0)
            let data = Data(String(repeating: "a", count: 64).utf8)
            _ = data.withUnsafeBytes { write(token[1], $0.baseAddress, $0.count) }
            XCTAssertThrowsError(try GUIVirtualContext(.init(
                tokenFD: token[0],
                readyFD: ready[1],
                port: 0,
                inputCapacity: nil
            )))
            close(token[1]); close(ready[0])
            XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("gui-invalid-pipe-\(UUID().uuidString)")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let fd = open(file.path, O_RDONLY)
            XCTAssertGreaterThan(fd, STDERR_FILENO)
            defer { close(fd) }
            XCTAssertThrowsError(try GUIVirtualContext.validatePipe(fd, writable: false))
            XCTAssertEqual(ConsoleConstructionAudit.counts, baseline)
        }

        func testConcurrentFinishJoinsTheOneActualCleanupResult() async throws {
            let (context, reader) = try context()
            let model = model(context), controller = try XCTUnwrap(model.deviceWork.guiVirtualSurface)
            let first = Task { @MainActor in await controller.finish() }
            let second = Task { @MainActor in await controller.finish() }
            let a = await first.value, b = await second.value
            XCTAssertEqual(a, b)
            XCTAssertTrue(a.isEmpty)
            _ = await reader.value
        }

        func testEarlyDelegateTerminationReportsFailedCleanupToCaller() async throws {
            let marker = "BCR_GUI_EARLY_TERMINATION_CHILD"
            if ProcessInfo.processInfo.environment[marker] == "1" {
                var token = [Int32](repeating: -1, count: 2)
                XCTAssertEqual(pipe(&token), 0)
                let data = Data(String(repeating: "a", count: 64).utf8)
                _ = data.withUnsafeBytes { write(token[1], $0.baseAddress, $0.count) }; close(token[1])
                let ready = dup(STDOUT_FILENO)
                let context = try GUIVirtualContext(.init(
                    tokenFD: token[0],
                    readyFD: ready,
                    port: 0,
                    inputCapacity: nil
                ))
                try FileManager.default.removeItem(at: context.directory)
                let delegate = ConsoleAppDelegate()
                delegate.guiVirtualContext = context
                XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
                try await Task.sleep(for: .seconds(3))
                return
            }
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = [
                "xctest",
                "-XCTest",
                "BCRAgentConsoleTests.GUIVirtualSurfaceTests/testEarlyDelegateTerminationReportsFailedCleanupToCaller",
                Bundle(for: Self.self).bundleURL.path
            ]
            child.environment = ProcessInfo.processInfo.environment.merging([marker: "1"]) { _, new in new }
            child.standardOutput = output; child.standardError = FileHandle.nullDevice
            try child.run()
            let raw = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 2)
            let records = raw.split(separator: 10)
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            let final = try XCTUnwrap(records.first { $0["event"] as? String == "gui_virtual.stopped" })
            XCTAssertTrue((final["cleanup_failed"] as? [String] ?? []).contains("owned_directory_unconfirmed"))
        }
    }
#endif
