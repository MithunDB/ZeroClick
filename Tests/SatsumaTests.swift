import AppleArchive
import AppKit
import CoreImage
import Foundation
import PDFKit
import System

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

final class TestRunner {
    private var failures: [String] = []
    private var count = 0

    func test(_ name: String, _ body: () throws -> Void) {
        count += 1
        do {
            try body()
            print("  ok   \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("  FAIL \(name): \(error)")
        }
    }

    func testAsync(_ name: String, _ body: () async throws -> Void) async {
        count += 1
        do {
            try await body()
            print("  ok   \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("  FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(count - failures.count)/\(count) passed")
        exit(failures.isEmpty ? 0 : 1)
    }
}

func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) throws {
    if !condition { throw TestFailure(description: "\(message) (\(file):\(line))") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if a != b { throw TestFailure(description: "\(message) expected \(b), got \(a) (\(file):\(line))") }
}

struct TestConversionEngine: ConversionEngine {
    enum Behavior { case write, missingOutput, emptyDirectory, waitForCancellation }
    let behavior: Behavior

    func supports(from: FileFormat, to: FileFormat) -> Bool { true }

    func convert(_ request: ConversionRequest) async throws {
        switch behavior {
        case .write:
            try Data("new output".utf8).write(to: request.destination)
        case .missingOutput:
            break
        case .emptyDirectory:
            try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: false)
        case .waitForCancellation:
            try Data("partial".utf8).write(to: request.destination)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

@main
struct SatsumaTests {
    static func main() async {
        let runner = TestRunner()

        runner.test("personal upscaler models import as matched pairs outside app resources") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let source = root.appendingPathComponent("source", isDirectory: true)
            let installed = root.appendingPathComponent("installed", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let parameter = source.appendingPathComponent("sample-4x.param")
            let weights = source.appendingPathComponent("sample-4x.bin")
            try Data("parameter".utf8).write(to: parameter)
            try Data("weights".utf8).write(to: weights)
            let model = try UpscaleModelCatalog.importPair(parameter: parameter, weights: weights, into: installed)
            try expectEqual(model.name, "sample-4x")
            try expectEqual(UpscaleModelCatalog.models(in: installed).map(\.name), ["sample-4x"])
            try expectEqual(try Data(contentsOf: model.weightFile), Data("weights".utf8))
            try expect(FileManager.default.fileExists(atPath: weights.path), "import must keep source model files")
            let second = try UpscaleModelCatalog.importPair(parameter: parameter, weights: weights, into: installed)
            try expect(model.directory != second.directory, "repeated imports must not overwrite")
            let mismatched = source.appendingPathComponent("other-4x.bin")
            try Data("other".utf8).write(to: mismatched)
            do {
                _ = try UpscaleModelCatalog.importPair(parameter: parameter, weights: mismatched, into: installed)
                throw TestFailure(description: "mismatched pair accepted")
            } catch is TestFailure { throw TestFailure(description: "mismatched pair accepted") }
            catch { /* expected */ }
            try expectEqual(UpscaleModelCatalog.models(in: installed).count, 2)
            let ultrasharp = UpscaleModel(name: "ultrasharp-4x", directory: installed,
                                         parameterFile: parameter, weightFile: weights)
            try expectEqual(ultrasharp.displayName, "UltraSharp 4× · non-commercial")
            try expectEqual(ultrasharp.nativeScale, 4)
        }

        runner.test("upscaler uses fixed file arguments and validates scale and format") {
            let root = URL(fileURLWithPath: "/tmp/test model")
            let model = UpscaleModel(name: "example-4x", directory: root,
                parameterFile: root.appendingPathComponent("example-4x.param"),
                weightFile: root.appendingPathComponent("example-4x.bin"))
            let input = URL(fileURLWithPath: "/tmp/photo; touch nope.png")
            let output = URL(fileURLWithPath: "/tmp/result.png")
            let args = try UpscaleEngine.arguments(input: input, output: output, model: model, scale: 4, format: .png)
            try expectEqual(args, ["-i", input.path, "-o", output.path, "-m", root.path,
                                   "-n", "example-4x", "-s", "4", "-f", "png"])
            try expectEqual(try UpscaleEngine.stages(nativeScale: 4, requestedScale: 8), [
                .init(inputScale: 1, inferredScale: 4, outputScale: 2),
                .init(inputScale: 2, inferredScale: 8, outputScale: 8),
            ])
            try expectEqual(try UpscaleEngine.stages(nativeScale: 4, requestedScale: 5), [
                .init(inputScale: 1, inferredScale: 4, outputScale: 2),
                .init(inputScale: 2, inferredScale: 8, outputScale: 5),
            ])
            try expectEqual(try UpscaleEngine.stages(nativeScale: 2, requestedScale: 8).count, 3)
            try expectEqual(UpscaleEngine.maximumSafeScale(for: [CGSize(width: 409, height: 512)], nativeScale: 4), 8)
            try expectEqual(UpscaleEngine.maximumSafeScale(for: [CGSize(width: 2048, height: 2560)], nativeScale: 4), 4)
            try expectEqual(UpscaleEngine.maximumSafeScale(for: [CGSize(width: 5256, height: 5264)], nativeScale: 4), 0)
            do {
                _ = try UpscaleEngine.arguments(input: input, output: output, model: model, scale: 8, format: .png)
                throw TestFailure(description: "unsupported scale accepted")
            } catch is TestFailure { throw TestFailure(description: "unsupported scale accepted") }
            catch { /* expected */ }
            let selected = [URL(fileURLWithPath: "/tmp/a/photo.png"), URL(fileURLWithPath: "/tmp/b/photo.jpg")]
            let destinations = UpscaleEngine.destinations(for: selected, scale: 4, format: .png) { _ in root }
            try expectEqual(destinations.count, 2)
            try expect(destinations[0] != destinations[1], "same-name batch inputs must reserve distinct outputs")
            try expect(destinations.allSatisfy { $0.lastPathComponent.contains("upscaled 4x") }, "output names should identify the operation")
        }

        await runner.testAsync("bundled upscaler creates a readable new copy without changing its source") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("tiny.png")
            guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw TestFailure(description: "Could not create source bitmap")
            }
            for (x, y, color) in [(0, 0, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                                  (32, 0, CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
                                  (0, 32, CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
                                  (32, 32, CGColor(red: 1, green: 1, blue: 0, alpha: 1))] {
                context.setFillColor(color)
                context.fill(CGRect(x: x, y: y, width: 32, height: 32))
            }
            guard let image = context.makeImage() else { throw TestFailure(description: "Could not render source bitmap") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try ImageIOBridge.write(image, to: source, format: .png)
            let original = try Data(contentsOf: source)
            let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Upscaler", isDirectory: true)
            let models = UpscaleModelCatalog.models(in: bundled.appendingPathComponent("models"), nested: false)
            guard let model = models.first, model.name == "realesr-animevideov3-x4" else {
                throw TestFailure(description: "Pinned bundled model missing")
            }
            let destination = root.appendingPathComponent("tiny upscaled 2x.png")
            let produced = try await UpscaleEngine.upscale(source: source, destination: destination, model: model,
                scale: 2, format: .png, executable: bundled.appendingPathComponent("realesrgan-ncnn-vulkan"))
            try expectEqual(produced, destination)
            try expectEqual(ImageIOBridge.pixelSize(produced), CGSize(width: 128, height: 128))
            let outputBitmap = NSBitmapImageRep(cgImage: try ImageIOBridge.load(produced))
            for (x, y) in [(8, 8), (56, 8), (8, 56), (56, 56)] {
                guard let originalColor = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let outputColor = outputBitmap.colorAt(x: x * 2, y: y * 2)?.usingColorSpace(.deviceRGB) else {
                    throw TestFailure(description: "Could not sample upscaled image")
                }
                let difference = abs(originalColor.redComponent - outputColor.redComponent)
                    + abs(originalColor.greenComponent - outputColor.greenComponent)
                    + abs(originalColor.blueComponent - outputColor.blueComponent)
                try expect(difference < 0.6, "2× output moved image quadrants")
            }
            try expectEqual(try Data(contentsOf: source), original)
            let firstOutput = try Data(contentsOf: produced)
            do {
                _ = try await UpscaleEngine.upscale(source: source, destination: destination, model: model,
                    scale: 2, format: .png, executable: bundled.appendingPathComponent("realesrgan-ncnn-vulkan"))
                throw TestFailure(description: "upscaler replaced an occupied output")
            } catch is TestFailure { throw TestFailure(description: "upscaler replaced an occupied output") }
            catch { /* expected: occupied destination */ }
            try expectEqual(try Data(contentsOf: destination), firstOutput)
            try expectEqual(try Data(contentsOf: source), original)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            try expect(!leftovers.contains { $0.hasPrefix(".zeroclick-") }, "failed publication left a staged output")
            let cancelledDestination = root.appendingPathComponent("cancelled.png")
            let cancelled = Task { () throws -> [URL] in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await UpscaleEngine.upscaleBatch(files: [source], destinations: [cancelledDestination],
                    model: model, scale: 2, format: .png,
                    executable: bundled.appendingPathComponent("realesrgan-ncnn-vulkan")) { _ in }
            }
            do {
                _ = try await cancelled.value
                throw TestFailure(description: "cancelled upscaler published an output")
            } catch is TestFailure { throw TestFailure(description: "cancelled upscaler published an output") }
            catch { /* expected */ }
            try expect(!FileManager.default.fileExists(atPath: cancelledDestination.path), "cancelled run published output")
            // The backend rejects UUID-named model folders directly. Exercise
            // the same imported-folder layout used by the personal model UI.
            let personal = try UpscaleModelCatalog.importPair(parameter: model.parameterFile,
                weights: model.weightFile, into: root.appendingPathComponent("PersonalModels"))
            let personalOutput = root.appendingPathComponent("personal upscaled.png")
            _ = try await UpscaleEngine.upscale(source: source, destination: personalOutput,
                model: personal, scale: 4, format: .png,
                executable: bundled.appendingPathComponent("realesrgan-ncnn-vulkan"))
            try expectEqual(ImageIOBridge.pixelSize(personalOutput), CGSize(width: 256, height: 256))
            let eightOutput = root.appendingPathComponent("personal upscaled 8x.png")
            _ = try await UpscaleEngine.upscale(source: source, destination: eightOutput,
                model: personal, scale: 8, format: .png,
                executable: bundled.appendingPathComponent("realesrgan-ncnn-vulkan"))
            try expectEqual(ImageIOBridge.pixelSize(eightOutput), CGSize(width: 512, height: 512))
            guard let previewData = ImageIOBridge.boundedPreviewData(eightOutput, maxPixelSize: 96) else {
                throw TestFailure(description: "Bounded upscaler preview failed")
            }
            let boundedPreview = root.appendingPathComponent("bounded-preview.png")
            try previewData.write(to: boundedPreview)
            try expectEqual(ImageIOBridge.pixelSize(boundedPreview), CGSize(width: 96, height: 96))
            let eightBitmap = NSBitmapImageRep(cgImage: try ImageIOBridge.load(eightOutput))
            for (x, y) in [(8, 8), (56, 8), (8, 56), (56, 56)] {
                guard let originalColor = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let outputColor = eightBitmap.colorAt(x: x * 8, y: y * 8)?.usingColorSpace(.deviceRGB) else {
                    throw TestFailure(description: "Could not sample 8× output")
                }
                let difference = abs(originalColor.redComponent - outputColor.redComponent)
                    + abs(originalColor.greenComponent - outputColor.greenComponent)
                    + abs(originalColor.blueComponent - outputColor.blueComponent)
                try expect(difference < 0.7, "8× output moved image quadrants")
            }
            let fiveOutput = root.appendingPathComponent("personal upscaled 5x.png")
            _ = try await UpscaleEngine.upscale(source: source, destination: fiveOutput,
                model: personal, scale: 5, format: .png,
                executable: bundled.appendingPathComponent("realesrgan-ncnn-vulkan"))
            try expectEqual(ImageIOBridge.pixelSize(fiveOutput), CGSize(width: 320, height: 320))
            try expectEqual(try Data(contentsOf: source), original)
        }

        runner.test("conversion matrix has 190 options") {
            try expectEqual(ConversionMatrix.totalConversions, 190)
        }

        runner.test("33 advanced tools") {
            try expectEqual(ToolID.total, 33)
        }

        runner.test("action registry filters conversion and tools") {
            let png = ActionRegistry.items(for: .convert, formats: [.png])
            try expect(png.contains { $0.action == .convert(.jpg) }, "PNG must offer JPG")
            try expect(!png.contains { $0.action == .convert(.mp3) }, "PNG should not show unrelated audio formats")
            let pdf = ActionRegistry.items(for: .tools, formats: [.pdf, .pdf])
            try expect(pdf.contains { $0.action == .tool(.mergePDF) }, "PDF pair must offer merge")
            try expect(!pdf.contains { $0.action == .tool(.cropImage) }, "PDF should not show unrelated image tools")
            try expect(!pdf.contains { $0.action == .tool(.unlockPDF) }, "PDF unlocking belongs on File Actions")
            try expect(ActionRegistry.items(for: .actions, formats: [.pdf]).contains { $0.action == .tool(.unlockPDF) && !$0.isEnabled }, "Plain PDF should show disabled Unlock PDF on File Actions")
            let imageTools = ActionRegistry.items(for: .tools, formats: [.png])
            try expect(imageTools.contains { $0.action == .tool(.upscaleImage) }, "PNG must show Upscale")
            try expect(!pdf.contains { $0.action == .tool(.upscaleImage) }, "PDF should not show image upscaling")
        }

        runner.test("quick wedges keep per-wheel successful history and grey inapplicable actions") {
            let store = FileManager.default.temporaryDirectory.appendingPathComponent("quick-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: store) }
            let formats = ActionRegistry.items(for: .convert, formats: [.png])
            let empty = QuickActionHistory.shortcuts(for: .convert, among: formats, from: store)
            try expectEqual(empty.count, 3)
            try expect(empty.allSatisfy { $0.1 == nil }, "new history should show disabled placeholders")
            let noTargets = ActionRegistry.displayItems(for: .convert, formats: [], historyURL: store)
            try expectEqual(noTargets.count, 3)
            try expect(noTargets.allSatisfy { $0.quickSlot != nil && !$0.isEnabled },
                       "a wheel with no conversion targets should retain three disabled quick wedges")
            try QuickActionHistory.record(.convert(.png), in: .convert, outcome: .cancelled, to: store)
            try QuickActionHistory.record(.convert(.png), in: .convert, outcome: .failed, to: store)
            try expect(QuickActionHistory.shortcuts(for: .convert, among: formats, from: store).allSatisfy { $0.1 == nil },
                       "failed or cancelled jobs polluted quick history")
            try QuickActionHistory.recordSuccess(.convert(.jpg), in: .convert, to: store)
            try QuickActionHistory.recordSuccess(.convert(.jpg), in: .convert, to: store)
            try QuickActionHistory.recordSuccess(.convert(.webp), in: .convert, to: store)
            try QuickActionHistory.recordSuccess(.fileAction(.copyPath), in: .actions, to: store)
            let image = QuickActionHistory.shortcuts(for: .convert, among: formats, from: store)
            try expectEqual(image[0].1?.action, .convert(.webp))
            try expectEqual(image[1].1?.action, .convert(.jpg))
            try expect(image[2].1 == nil, "third slot must not duplicate the last action")
            let document = QuickActionHistory.shortcuts(for: .convert,
                among: ActionRegistry.items(for: .convert, formats: [.pdf]), from: store)
            try expect(document[0].1?.action == .convert(.webp) && document[0].1?.isEnabled == false,
                       "last action should stay visible but grey for another category")
            let fileActions = QuickActionHistory.shortcuts(for: .actions,
                among: ActionRegistry.items(for: .actions, formats: [.png]), from: store)
            try expectEqual(fileActions[0].1?.action, .fileAction(.copyPath))
            try expect(fileActions[1].1 == nil, "conversion frequency leaked into File Actions")
            try expect(QuickActionHistory.shortcuts(for: .ai, among: [], from: store).isEmpty,
                       "disabled AI must have no quick actions")
        }

        runner.test("quick wedges occupy fixed left-side angles and remain hittable") {
            let geometry = RadialGeometry(count: 9, quickCount: 3)
            for index in 6..<9 {
                let angle = geometry.angles(for: index)
                let center = (angle.start + angle.end) / 2
                try expect(cos(center) < -0.8, "quick wedge is not on the left")
                let hit = geometry.index(at: CGPoint(x: cos(center) * 100, y: sin(center) * 100))
                try expectEqual(hit, index)
            }
            let regular = geometry.angles(for: 0)
            try expectEqual(geometry.index(at: CGPoint(x: cos((regular.start + regular.end) / 2) * 100,
                                                      y: sin((regular.start + regular.end) / 2) * 100)), 0)
            let dense = RadialGeometry(innerRadius: 82, outerRadius: 210, count: 15, quickCount: 3)
            try expect(dense.labelWidth(for: 0) > 50, "dense Command wheel needs readable wedge width")
            for index in 0..<15 {
                let angles = dense.angles(for: index)
                let middle = (angles.start + angles.end) / 2
                try expectEqual(dense.index(at: CGPoint(x: cos(middle) * 150, y: sin(middle) * 150)), index)
            }
        }

        runner.test("mixed selections expose only common actions") {
            let mixedDocuments = ActionRegistry.items(for: .convert, formats: [.png, .pdf], ffmpegAvailable: false)
            try expect(mixedDocuments.contains { $0.action == .convert(.docx) }, "PNG and PDF both support DOCX")
            try expect(mixedDocuments.contains { $0.action == .convert(.png) && !$0.isEnabled }, "PNG self-conversion should be visible but disabled")
            try expect(ActionRegistry.items(for: .convert, formats: [.png, .mp3], ffmpegAvailable: false).allSatisfy { !$0.isEnabled }, "unrelated formats have no enabled common conversion")
            try expect(ActionRegistry.items(for: .tools, formats: [.png, .pdf]).allSatisfy { !$0.isEnabled }, "mixed categories have no enabled single-category tools")
            let paths = [URL(fileURLWithPath: "/tmp/photo.png"), URL(fileURLWithPath: "/tmp/song.mp3")]
            let actions = ActionRegistry.items(for: .actions, formats: [.png, .mp3], urls: paths)
            try expect(actions.contains { $0.action == .fileAction(.createZip) }, "mixed files can be archived together")
            try expect(!actions.contains { $0.action == .fileAction(.extractZip) }, "mixed nonarchives should not crowd File Actions with ZIP extraction")
        }

        runner.test("partly unsupported selections cannot enable conversion or tools") {
            let paths = [URL(fileURLWithPath: "/tmp/photo.png"), URL(fileURLWithPath: "/tmp/unknown.bin")]
            let conversions = ActionRegistry.items(for: .convert, formats: [.png], urls: paths)
            let tools = ActionRegistry.items(for: .tools, formats: [.png], urls: paths)
            try expect(!conversions.isEmpty && conversions.allSatisfy { !$0.isEnabled }, "Conversion must not use only the recognized subset")
            try expect(!tools.isEmpty && tools.allSatisfy { !$0.isEnabled }, "Tools must not use only the recognized subset")
        }

        runner.test("redaction selection returns to newest area after background click or removal") {
            let first = RectangleOverlay(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10), color: .orange, label: "1")
            let top = RectangleOverlay(id: UUID(), rect: CGRect(x: 20, y: 20, width: 10, height: 10), color: .orange, label: "2")
            try expectEqual(RedactionSelection.activeID(nil, among: [first, top]), top.id)
            try expectEqual(RedactionSelection.activeID(first.id, among: [first, top]), first.id)
            try expectEqual(RedactionSelection.activeID(first.id, among: [first, top], newlyAdded: [top.id]), top.id)
            try expectEqual(RedactionSelection.activeID(top.id, among: [first]), first.id)
            try expectEqual(RedactionSelection.activeID(first.id, among: []), nil)
        }

        runner.test("conversion wheel disables FFmpeg-only actions when unavailable") {
            let nativeVideo = ActionRegistry.items(for: .convert, formats: [.mp4], ffmpegAvailable: false)
            try expect(nativeVideo.contains { $0.action == .convert(.mov) }, "native MOV should remain")
            try expect(nativeVideo.contains { $0.action == .convert(.mkv) && !$0.isEnabled }, "MKV requires FFmpeg")
            try expect(nativeVideo.contains { $0.action == .convert(.mp3) && !$0.isEnabled }, "MP3 requires FFmpeg")
            try expect(ActionRegistry.items(for: .convert, formats: [.mkv], ffmpegAvailable: false).allSatisfy { !$0.isEnabled }, "MKV source needs FFmpeg")
            let withFFmpeg = ActionRegistry.items(for: .convert, formats: [.mp4], ffmpegAvailable: true)
            try expect(withFFmpeg.contains { $0.action == .convert(.mkv) }, "MKV should appear with FFmpeg")
        }

        runner.test("broken local tools and absent bsdtar disable dependent conversions") {
            try expect(!LocalToolHealth.responds("/usr/bin/false", arguments: []), "failed executable looked healthy")
            try expect(!LocalToolHealth.responds("/missing/zeroclick-tool", arguments: []), "missing executable looked healthy")
            let rar = ActionRegistry.items(for: .convert, formats: [.rar], bsdtarAvailable: false)
            try expect(!rar.isEmpty && rar.allSatisfy { !$0.isEnabled } &&
                       rar.contains { $0.disabledReason?.contains("bsdtar") == true },
                "RAR conversion remained enabled without bsdtar")
        }

        runner.test("new encryption formats are native while legacy files remain decryptable") {
            try expectEqual(Set(EncryptionFormat.allCases), Set([.appleArchive, .diskImage]))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-legacy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("old.txt")
            let protected = folder.appendingPathComponent("old.txt.zclick")
            try Data("legacy access".utf8).write(to: source)
            _ = try SecureFile.encrypt(source, password: "legacy-test-password", to: protected)
            try expect(ActionRegistry.items(for: .actions, formats: [], urls: [protected]).contains {
                $0.action == .tool(.decryptFile) && $0.isEnabled
            }, "legacy decrypt action disappeared")
            let output = try SecureFile.decrypt(protected, password: "legacy-test-password", into: folder)
            try expectEqual(try Data(contentsOf: output), Data("legacy access".utf8))
        }

        runner.test("AI actions are visible and disabled") {
            let items = ActionRegistry.items(for: .ai, formats: [.png])
            try expectEqual(items.count, 6)
            try expect(items.allSatisfy { !$0.isEnabled && $0.detail.contains("Coming later") }, "AI actions must remain disabled")
        }

        runner.test("tools wheel modifier mapping preserves both choices") {
            try expectEqual(DragMonitor.wheelMode(for: [.shift, .option], toolsModifier: .shiftOption), .tools)
            try expectEqual(DragMonitor.wheelMode(for: [.command], toolsModifier: .shiftOption), .actions)
            try expectEqual(DragMonitor.wheelMode(for: [.command], toolsModifier: .command), .tools)
            try expectEqual(DragMonitor.wheelMode(for: [.command, .option], toolsModifier: .command), .actions)
            try expectEqual(DragMonitor.wheelMode(for: [.shift], toolsModifier: .command), .convert)
            try expectEqual(DragMonitor.wheelMode(for: [.option], toolsModifier: .command), .ai)
            try expectEqual(DragMonitor.wheelMode(for: [.control], toolsModifier: .command), .actions)
        }

        runner.test("wheel modes have distinct center labels") {
            try expectEqual(WheelMode.convert.centerTitle, "CONVERT")
            try expectEqual(WheelMode.tools.centerTitle, "TOOLS")
            try expectEqual(WheelMode.actions.centerTitle, "FILE ACTIONS")
            try expectEqual(WheelMode.ai.centerTitle, "AI · COMING LATER")
        }

        runner.test("long Finder drags cancel beyond the wheel intent radius") {
            let origin = NSPoint(x: 100, y: 100)
            try expect(!DragMonitor.exceedsIntentDistance(from: origin, to: NSPoint(x: 100, y: 399)), "wheel range should remain usable")
            try expect(DragMonitor.exceedsIntentDistance(from: origin, to: NSPoint(x: 100, y: 401)), "long drag must cancel")
        }

        runner.test("file actions apply to folders and unsupported types") {
            let items = ActionRegistry.items(for: .actions, formats: [])
            try expectEqual(items.count, 9)
            try expect(items.contains { $0.action == .fileAction(.copyPath) && $0.isEnabled }, "Copy Path must be available")
            try expect(items.contains { $0.action == .fileAction(.duplicate) && $0.isEnabled }, "Duplicate must be available")
            try expect(!items.contains { $0.action == .fileAction(.extractZip) }, "Extract ZIP is only shown for archives")
        }

        await runner.testAsync("ZIP action creates and extracts without replacing source") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("notes.txt")
            try "hello archive".write(to: source, atomically: true, encoding: .utf8)
            let destination = ArchiveActionRunner.zipDestination(for: [source])
            let zip = try await ArchiveActionRunner.createZip(from: [source], to: destination)
            try expectEqual(FileFormat.detect(zip), .zip)
            let originalArchive = try Data(contentsOf: zip)
            do {
                try await ZipTool.zip(directory: folder, to: zip)
                throw TestFailure(description: "ZIP writer replaced existing archive")
            } catch is TestFailure {
                throw TestFailure(description: "ZIP writer replaced existing archive")
            } catch {
                try expectEqual(try Data(contentsOf: zip), originalArchive)
            }
            try expect(ArchiveActionRunner.zipDestination(for: [source]) != zip, "repeat must choose another name")
            let extracted = try await ArchiveActionRunner.extractZip(zip, to: ArchiveActionRunner.extractionDestination(for: zip))
            try expectEqual(try String(contentsOf: extracted.appendingPathComponent("notes.txt"), encoding: .utf8), "hello archive")
            let repackedOutput = folder.appendingPathComponent("repacked output")
            try FileManager.default.createDirectory(at: repackedOutput, withIntermediateDirectories: true)
            try await ArchiveEngine().extract(zip, format: .rar, into: repackedOutput)
            try expectEqual(try String(contentsOf: repackedOutput.appendingPathComponent("notes.txt"), encoding: .utf8), "hello archive")
            try expectEqual(try String(contentsOf: source, encoding: .utf8), "hello archive")
            try expect(ActionRegistry.items(for: .actions, formats: [.zip], urls: [zip]).contains { $0.action == .fileAction(.extractZip) }, "ZIP must offer extraction")

            var hostile = try Data(contentsOf: zip)
            let filename = Data("notes.txt".utf8)
            let replacement = Data("../a.txt/".utf8)
            guard let nameRange = hostile.range(of: filename, options: .backwards) else {
                throw TestFailure(description: "ZIP central filename missing")
            }
            hostile.replaceSubrange(nameRange, with: replacement)
            let hostileURL = folder.appendingPathComponent("hostile.zip")
            try hostile.write(to: hostileURL)
            let rejectedDestination = folder.appendingPathComponent("hostile extracted")
            do {
                _ = try await ArchiveActionRunner.extractZip(hostileURL, to: rejectedDestination)
                throw TestFailure(description: "parent path was accepted")
            } catch is TestFailure {
                throw TestFailure(description: "parent path was accepted")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: rejectedDestination.path), "rejected ZIP must leave no output")
            }

            var mismatched = originalArchive
            guard let localRange = mismatched.range(of: filename) else {
                throw TestFailure(description: "ZIP local filename missing")
            }
            mismatched.replaceSubrange(localRange, with: replacement)
            let mismatchURL = folder.appendingPathComponent("mismatch.zip")
            try mismatched.write(to: mismatchURL)
            do {
                try ZipSafety.validate(mismatchURL)
                throw TestFailure(description: "mismatched ZIP headers were accepted")
            } catch is TestFailure {
                throw TestFailure(description: "mismatched ZIP headers were accepted")
            } catch {}

            let link = folder.appendingPathComponent("shortcut")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let linkArchive = folder.appendingPathComponent("link.zip")
            let linkZip = try await Shell.run("/usr/bin/zip", ["-y", "-q", linkArchive.path, link.lastPathComponent], currentDirectory: folder)
            try expect(linkZip.succeeded, "symlink ZIP fixture")
            do {
                _ = try await ArchiveActionRunner.extractZip(linkArchive, to: folder.appendingPathComponent("link output"))
                throw TestFailure(description: "symlink ZIP was accepted")
            } catch is TestFailure {
                throw TestFailure(description: "symlink ZIP was accepted")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("link output").path), "rejected symlink ZIP must leave no output")
            }
            let repackedLinkOutput = folder.appendingPathComponent("repacked link output")
            try FileManager.default.createDirectory(at: repackedLinkOutput, withIntermediateDirectories: true)
            do {
                try await ArchiveEngine().extract(linkArchive, format: .rar, into: repackedLinkOutput)
                throw TestFailure(description: "repacked symlink was accepted")
            } catch is TestFailure {
                throw TestFailure(description: "repacked symlink was accepted")
            } catch {
                try expect(try FileManager.default.contentsOfDirectory(atPath: repackedLinkOutput.path).isEmpty, "rejected repack must leave no files")
            }
        }

        await runner.testAsync("protected ZIP rejects wrong password and preserves its source") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("secret.txt")
            try "private fixture".write(to: source, atomically: true, encoding: .utf8)
            let zip = folder.appendingPathComponent("protected.zip")
            // This is a synthetic test-only password; app passwords never enter process arguments.
            let result = try await Shell.run("/usr/bin/zip", ["-q", "-P", "test-zip-42", zip.path, source.lastPathComponent], currentDirectory: folder)
            try expect(result.succeeded, "protected ZIP fixture creation")
            let original = try Data(contentsOf: zip)
            try expect(try ZipSafety.validate(zip).isEncrypted, "ZIP encryption flag must be detected")
            try expect(ActionRegistry.items(for: .actions, formats: [.zip], urls: [zip]).contains { $0.action == .tool(.unlockZIP) }, "protected ZIP must offer unlock")
            let wrong = folder.appendingPathComponent("wrong output")
            do {
                _ = try await ArchiveActionRunner.extractProtectedZip(zip, password: "wrong", to: wrong)
                throw TestFailure(description: "wrong ZIP password was accepted")
            } catch is TestFailure {
                throw TestFailure(description: "wrong ZIP password was accepted")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: wrong.path), "failed extraction left an output folder")
            }
            let destination = folder.appendingPathComponent("unlocked output")
            let extracted = try await ArchiveActionRunner.extractProtectedZip(zip, password: "test-zip-42", to: destination)
            try expectEqual(try String(contentsOf: extracted.appendingPathComponent("secret.txt"), encoding: .utf8), "private fixture")
            try expectEqual(try Data(contentsOf: zip), original)
        }

        await runner.testAsync("AES-encrypted ZIP extracts with the correct password") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            // Tiny synthetic WinZip AES-256 fixture generated with pyzipper for this test.
            let base64 = "UEsDBBQAAQBjAKeyU10AAAAAKAAAAAoAAAAHAAsAYWVzLnR4dAGZBwACAEFFAwgAWmMr1xZCcOUtQE8BzO5UFhEMZeJM4AmLKqp7uYJbqg9zdf9WRKqu5FBLAQIUAxQAAQBjAKeyU10AAAAAKAAAAAoAAAAHAAsAAAAAAAAAAACAAQAAAABhZXMudHh0AZkHAAIAQUUDCABQSwUGAAAAAAEAAQBAAAAAWAAAAAAA"
            guard let bytes = Data(base64Encoded: base64) else { throw TestFailure(description: "Invalid AES fixture") }
            let zip = folder.appendingPathComponent("aes.zip")
            try bytes.write(to: zip)
            try expect(try ZipSafety.validate(zip).isEncrypted, "AES ZIP must be detected as encrypted")
            let destination = folder.appendingPathComponent("aes extracted")
            let extracted = try await ArchiveActionRunner.extractProtectedZip(zip, password: "test-aes-42", to: destination)
            try expectEqual(try String(contentsOf: extracted.appendingPathComponent("aes.txt"), encoding: .utf8), "AES sample")
            try expectEqual(try Data(contentsOf: zip), bytes)
        }

        await runner.testAsync("real RAR archive extracts safely without changing its source") {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/rar-multi-lzss-blocks.rar")
            let bytes = try Data(contentsOf: fixture)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let extracted = folder.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try await ArchiveEngine().extract(fixture, format: .rar, into: extracted)
            let content = try Data(contentsOf: extracted.appendingPathComponent("multi_lzss_blocks_test.txt"))
            try expectEqual(content.count, 20_131_111)
            try expectEqual(try Data(contentsOf: fixture), bytes)
        }

        runner.test("ZeroClick encrypted file round-trips and rejects wrong password and tampering") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("notes.txt")
            let original = Data("private local notes".utf8)
            try original.write(to: source)
            let encrypted = folder.appendingPathComponent("notes.txt.zclick")
            _ = try SecureFile.encrypt(source, password: "test-secret-42", to: encrypted)
            try expect(SecureFile.isEncrypted(encrypted), "encrypted header must be detected")
            try expect(ActionRegistry.items(for: .actions, formats: [], urls: [encrypted]).contains { $0.action == .tool(.decryptFile) }, "encrypted file must offer decrypt")
            try expect(!ActionRegistry.items(for: .tools, formats: [], urls: [encrypted]).contains { $0.action == .tool(.decryptFile) }, "Tools wheel must not duplicate decrypt")
            try expect(ActionRegistry.items(for: .actions, formats: [.txt], urls: [source]).contains { $0.action == .tool(.encryptFile) }, "File Actions must offer encrypt")
            try expectEqual(try Data(contentsOf: source), original)
            do {
                _ = try SecureFile.decrypt(encrypted, password: "wrong", into: folder)
                throw TestFailure(description: "wrong password decrypted file")
            } catch is TestFailure {
                throw TestFailure(description: "wrong password decrypted file")
            } catch {}
            let decrypted = try SecureFile.decrypt(encrypted, password: "test-secret-42", into: folder)
            try expectEqual(try Data(contentsOf: decrypted), original)
            try expect(decrypted != source, "decrypted output replaced source")
            var altered = try Data(contentsOf: encrypted)
            altered[altered.count - 1] ^= 1
            let tampered = folder.appendingPathComponent("tampered.zclick")
            try altered.write(to: tampered)
            do {
                _ = try SecureFile.decrypt(tampered, password: "test-secret-42", into: folder)
                throw TestFailure(description: "tampered file decrypted")
            } catch is TestFailure {
                throw TestFailure(description: "tampered file decrypted")
            } catch {}
            try expectEqual(try Data(contentsOf: source), original)
        }

        await runner.testAsync("native DMG round-trips one file and rejects a wrong password") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-dmg-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("notes.txt")
            let archive = folder.appendingPathComponent("notes.txt.dmg")
            let original = Data("private disk image test".utf8)
            try original.write(to: source)
            try Data("sibling".utf8).write(to: folder.appendingPathComponent("unrelated.txt"))
            _ = try await NativeDiskImage.encrypt(source, password: "disposable-dmg-password", to: archive)
            try expectEqual(try Data(contentsOf: source), original)
            try expect(ActionRegistry.items(for: .actions, formats: [], urls: [archive]).contains {
                $0.action == .tool(.decryptFile) && $0.isEnabled
            }, "DMG decryption was not available")
            let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            do {
                _ = try await NativeDiskImage.decrypt(archive, password: "incorrect-password", into: folder)
                throw TestFailure(description: "wrong DMG password created output")
            } catch is TestFailure { throw TestFailure(description: "wrong DMG password created output") }
            catch {}
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before,
                "wrong DMG password left files")
            let occupied = folder.appendingPathComponent("notes decrypted.txt")
            try Data("occupied".utf8).write(to: occupied)
            let output = try await NativeDiskImage.decrypt(archive, password: "disposable-dmg-password", into: folder)
            try expectEqual(try Data(contentsOf: output), original)
            try expect(output != source && output != occupied, "DMG extraction replaced an existing file")
            try expectEqual(try Data(contentsOf: occupied), Data("occupied".utf8))
            try expectEqual(try Data(contentsOf: source), original)
            let cancelled = Task { try await NativeDiskImage.decrypt(
                archive, password: "disposable-dmg-password", into: folder) }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                throw TestFailure(description: "cancelled DMG extraction published a file")
            } catch is CancellationError {
                // Attach completes so the device can be ejected, then cancellation propagates.
            } catch is TestFailure { throw TestFailure(description: "cancelled DMG extraction published a file") }
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                (before + ["notes decrypted.txt", output.lastPathComponent]).sorted(),
                "cancelled DMG extraction left files")
        }

        await runner.testAsync("native DMG rejects plain and multi-file images without publishing output") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-dmg-reject-\(UUID().uuidString)")
            let contents = folder.appendingPathComponent("contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try Data("one".utf8).write(to: contents.appendingPathComponent("one.txt"))
            try Data("two".utf8).write(to: contents.appendingPathComponent("two.txt"))
            let plain = folder.appendingPathComponent("plain.dmg")
            let createdPlain = try await Shell.run("/usr/sbin/diskutil",
                ["image", "create", "from", "--format", "ULFO", contents.path, plain.path])
            try expect(createdPlain.succeeded, "plain DMG fixture failed")
            try expect(!NativeDiskImage.isEncrypted(plain), "plain DMG looked encrypted")
            try expect(!ActionRegistry.items(for: .actions, formats: [], urls: [plain]).contains {
                $0.action == .tool(.decryptFile) && $0.isEnabled
            }, "plain DMG offered enabled decryption")
            do {
                _ = try await NativeDiskImage.decrypt(plain, password: "disposable-dmg-password", into: folder)
                throw TestFailure(description: "plain DMG decrypted")
            } catch is TestFailure { throw TestFailure(description: "plain DMG decrypted") }
            catch {}
            let protected = folder.appendingPathComponent("multiple.dmg")
            let createdProtected = try await Shell.runWithInput("/usr/sbin/diskutil",
                ["image", "create", "from", "--encrypt", "--stdinpassphrase", "--format", "ULFO",
                 contents.path, protected.path], input: Data("disposable-dmg-password\n".utf8))
            try expect(createdProtected.succeeded, "protected DMG fixture failed")
            let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            do {
                _ = try await NativeDiskImage.decrypt(protected, password: "disposable-dmg-password", into: folder)
                throw TestFailure(description: "multi-file DMG decrypted")
            } catch is TestFailure { throw TestFailure(description: "multi-file DMG decrypted") }
            catch SatsumaError.invalidInput(let reason) {
                try expect(reason.contains("exactly one regular file"),
                    "multi-file DMG failed before content validation: \(reason)")
            } catch {
                throw TestFailure(description: "multi-file DMG failed before content validation: \(error)")
            }
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before,
                "rejected DMG left output")
        }

        runner.test("native AEA round-trips one file without replacing sources or occupied outputs") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("notes café.txt")
            let original = Data("private local notes ☕️".utf8)
            try original.write(to: source)
            try Data("unrelated".utf8).write(to: folder.appendingPathComponent("other.txt"))
            let archive = folder.appendingPathComponent("notes café.txt.aea")
            _ = try NativeEncryptedArchive.encrypt(source, password: "disposable-password-42", to: archive)
            try expectEqual(try Data(contentsOf: source), original)
            try expect(FileManager.default.fileExists(atPath: archive.path), "AEA was not created")
            try expect(NativeEncryptedArchive.isEncrypted(archive), "AEA header was not detected")
            try expect(ActionRegistry.items(for: .actions, formats: [], urls: [archive]).contains {
                $0.action == .tool(.decryptFile) && $0.isEnabled
            }, "File-actions wheel did not offer AEA decryption")
            let occupied = folder.appendingPathComponent("notes café decrypted.txt")
            try Data("occupied".utf8).write(to: occupied)
            let output = try NativeEncryptedArchive.decrypt(archive, password: "disposable-password-42", into: folder)
            try expectEqual(try Data(contentsOf: output), original)
            try expectEqual(try Data(contentsOf: occupied), Data("occupied".utf8))
            try expect(output != source && output != occupied, "decryption replaced a file")
            try expectEqual(try Data(contentsOf: source), original)
            try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("other decrypted.txt").path),
                       "AEA included a sibling file")
        }

        await runner.testAsync("native AEA async encrypts a Finder-like folder with multiple siblings") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            for name in ["sample-image.png", "sample.md", "sample.txt", "sample.zip", "TESTING_GUIDE.txt"] {
                try Data("disposable \(name)".utf8).write(to: folder.appendingPathComponent(name))
            }
            let source = folder.appendingPathComponent("sample.txt")
            let archive = folder.appendingPathComponent("sample.txt.aea")
            do {
                _ = try await NativeEncryptedArchive.encryptAsync(source, password: "demo-archive-2026", to: archive)
                throw TestFailure(description: "AppleArchive accepted a password shorter than 20 UTF-8 bytes")
            } catch is TestFailure {
                throw TestFailure(description: "AppleArchive accepted a password shorter than 20 UTF-8 bytes")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: archive.path), "short password left output")
            }
            _ = try await NativeEncryptedArchive.encryptAsync(source, password: "demo-archive-2026-long", to: archive)
            let output = try await NativeEncryptedArchive.decryptAsync(archive, password: "demo-archive-2026-long", into: folder)
            try expectEqual(try Data(contentsOf: output), try Data(contentsOf: source))
        }

        runner.test("native AEA rejects wrong passwords and malformed input without outputs") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("notes.txt")
            try Data("secret".utf8).write(to: source)
            let archive = folder.appendingPathComponent("notes.txt.aea")
            _ = try NativeEncryptedArchive.encrypt(source, password: "disposable-password-42", to: archive)
            for candidate in [archive, source] {
                do {
                    _ = try NativeEncryptedArchive.decrypt(candidate, password: "incorrect-password-42", into: folder)
                    throw TestFailure(description: "invalid archive or password produced output")
                } catch is TestFailure { throw TestFailure(description: "invalid archive or password produced output") }
                catch {}
            }
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                            ["notes.txt", "notes.txt.aea"], "failed extraction left files")
        }

        runner.test("native AEA rejects multiple entries and links without publishing files") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let contents = folder.appendingPathComponent("contents")
            let output = folder.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try Data("first".utf8).write(to: contents.appendingPathComponent("first.txt"))
            try Data("second".utf8).write(to: contents.appendingPathComponent("second.txt"))
            let archive = folder.appendingPathComponent("multiple.aea")
            let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none,
                                                   compressionAlgorithm: .lzfse)
            try context.setPassword("disposable-password-42")
            guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .writeOnly,
                    options: [.create, .exclusiveCreate], permissions: FilePermissions(rawValue: 0o600)),
                  let encrypted = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context),
                  let encoder = ArchiveStream.encodeStream(writingTo: encrypted),
                  let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,SIZ,MOD,MTM") else {
                throw TestFailure(description: "Could not create multiple-entry fixture")
            }
            try encoder.writeDirectoryContents(archiveFrom: FilePath(contents.path), keySet: keys)
            try encoder.close()
            try encrypted.close()
            try file.close()
            do {
                _ = try NativeEncryptedArchive.decrypt(archive, password: "disposable-password-42", into: output)
                throw TestFailure(description: "multiple-entry archive extracted")
            } catch is TestFailure { throw TestFailure(description: "multiple-entry archive extracted") }
            catch {}
            try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty,
                       "rejected archive left extracted content")
            try FileManager.default.removeItem(at: contents.appendingPathComponent("first.txt"))
            try FileManager.default.removeItem(at: contents.appendingPathComponent("second.txt"))
            try FileManager.default.createSymbolicLink(
                at: contents.appendingPathComponent("unsafe-link"), withDestinationURL: folder)
            let linkedArchive = folder.appendingPathComponent("link.aea")
            let linkContext = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none,
                                                       compressionAlgorithm: .lzfse)
            try linkContext.setPassword("disposable-password-42")
            guard let linkFile = ArchiveByteStream.fileStream(path: FilePath(linkedArchive.path), mode: .writeOnly,
                    options: [.create, .exclusiveCreate], permissions: FilePermissions(rawValue: 0o600)),
                  let linkEncrypted = ArchiveByteStream.encryptionStream(writingTo: linkFile, encryptionContext: linkContext),
                  let linkEncoder = ArchiveStream.encodeStream(writingTo: linkEncrypted),
                  let linkKeys = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,SIZ,MOD,MTM") else {
                throw TestFailure(description: "Could not create linked-entry fixture")
            }
            try linkEncoder.writeDirectoryContents(archiveFrom: FilePath(contents.path), keySet: linkKeys)
            try linkEncoder.close()
            try linkEncrypted.close()
            try linkFile.close()
            do {
                _ = try NativeEncryptedArchive.decrypt(linkedArchive, password: "disposable-password-42", into: output)
                throw TestFailure(description: "linked-entry archive extracted")
            } catch is TestFailure { throw TestFailure(description: "linked-entry archive extracted") }
            catch {}
            try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty,
                       "rejected linked archive left content")
        }

        await runner.testAsync("native AEA cancellation removes a partial encrypted output") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("large.bin")
            var bytes = Data(count: 48 * 1024 * 1024)
            bytes.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
            }
            try bytes.write(to: source)
            bytes.removeAll()
            let destination = folder.appendingPathComponent("large.bin.aea")
            let task = Task { try await NativeEncryptedArchive.encryptAsync(
                source, password: "disposable-password-42", to: destination) }
            var stageSeen = false
            for _ in 0..<1_000 {
                let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                if names.contains(where: { $0.hasPrefix(".zeroclick-") && $0.hasSuffix(".aea") }) {
                    stageSeen = true
                    break
                }
                if FileManager.default.fileExists(atPath: destination.path) { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try expect(stageSeen, "large archive finished before cancellation could be tested")
            task.cancel()
            do {
                _ = try await task.value
                throw TestFailure(description: "cancelled AEA was published")
            } catch is CancellationError {
                // Expected.
            } catch is TestFailure {
                throw TestFailure(description: "cancelled AEA was published")
            }
            try expect(!FileManager.default.fileExists(atPath: destination.path), "cancelled AEA exists")
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            try expectEqual(names.sorted(), ["large.bin"], "cancelled AEA left a staged file")
            let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue
            try expectEqual(size, 48 * 1024 * 1024, "cancelled AEA changed source size")
        }

        runner.test("OpenStego importer rejects an unrecognized JAR") {
            let fake = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jar")
            try Data("not OpenStego".utf8).write(to: fake)
            defer { try? FileManager.default.removeItem(at: fake) }
            do {
                _ = try OpenStegoBridge.importJar(fake)
                throw TestFailure(description: "unrecognized JAR was accepted")
            } catch is TestFailure {
                throw TestFailure(description: "unrecognized JAR was accepted")
            } catch {}
        }

        if let jarPath = ProcessInfo.processInfo.environment["ZEROCLICK_OPENSTEGO_TEST_JAR"] {
            await runner.testAsync("OpenStego RandomLSB interoperates without changing originals") {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: folder) }
                let jar = URL(fileURLWithPath: jarPath)
                let source = folder.appendingPathComponent("cover.png")
                let image = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
                    .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
                guard let cg = ImageToolSupport.cgImage(image) else {
                    throw TestFailure(description: "Could not make PNG fixture")
                }
                try ImageIOBridge.write(cg, to: source, format: .png)
                let original = try Data(contentsOf: source)
                let hidden = folder.appendingPathComponent("openstego hidden.png")
                _ = try await OpenStegoBridge.hide("OpenStego café ☕️", password: "demo-openstego-42",
                                                   in: source, to: hidden, jarOverride: jar)
                try expectEqual(try await OpenStegoBridge.reveal(from: hidden,
                                password: "demo-openstego-42", jarOverride: jar), "OpenStego café ☕️")
                try expectEqual(try Data(contentsOf: source), original, "OpenStego changed the cover")
                do {
                    _ = try await OpenStegoBridge.reveal(from: hidden, password: "wrong", jarOverride: jar)
                    throw TestFailure(description: "wrong OpenStego password worked")
                } catch is TestFailure {
                    throw TestFailure(description: "wrong OpenStego password worked")
                } catch {}
                try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                                [source.lastPathComponent, hidden.lastPathComponent].sorted(),
                                "OpenStego left plaintext or staged files")
            }
        }

        runner.test("Markdown PDF renders headings and emphasis without literal markers") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let styled = try MarkdownRenderer.attributed("# Heading\n\nA **bold** phrase and *italic* word.\n- First item")
            try expect(styled.string.contains("Heading"), "heading text must remain")
            try expect(!styled.string.contains("#") && !styled.string.contains("**"), "Markdown markers must be removed")
            let headingFont = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            try expect((headingFont?.pointSize ?? 0) > 11, "heading must be visually larger")
            let output = folder.appendingPathComponent("rendered.pdf")
            try TextRenderer.writePDF(styled, to: output)
            guard let document = PDFDocument(url: output), let text = document.string else {
                throw TestFailure(description: "Markdown PDF is unreadable")
            }
            try expect(text.contains("Heading") && text.contains("bold") && text.contains("First item"), "rendered text is incomplete")
        }

        await runner.testAsync("corrupt ZIP extraction leaves source and output folder untouched") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("broken.zip")
            let destination = folder.appendingPathComponent("broken extracted")
            let bytes = Data("not a ZIP archive".utf8)
            try bytes.write(to: source)
            do {
                _ = try await ArchiveActionRunner.extractZip(source, to: destination)
                throw TestFailure(description: "Corrupt ZIP was extracted")
            } catch is TestFailure {
                throw TestFailure(description: "Corrupt ZIP was extracted")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: destination.path), "Corrupt ZIP left an output folder")
                try expectEqual(try Data(contentsOf: source), bytes)
            }
        }

        await runner.testAsync("raw GZIP extracts binary content without a shell") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("payload.bin")
            let archive = folder.appendingPathComponent("payload.bin.gz")
            let output = folder.appendingPathComponent("out")
            let content = Data([0, 1, 2, 255, 0, 42])
            try content.write(to: source)
            let packed = try await Shell.runToFile("/usr/bin/gzip", ["-c", source.path], output: archive)
            try expect(packed.succeeded, "gzip fixture creation")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await ArchiveEngine().extract(archive, format: .gz, into: output)
            try expectEqual(try Data(contentsOf: output.appendingPathComponent("payload.bin")), content)
        }

        await runner.testAsync("TAR preflight accepts files and rejects links") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("safe.txt")
            try "safe".write(to: source, atomically: true, encoding: .utf8)
            let archive = folder.appendingPathComponent("safe.tar")
            let packed = try await Shell.run("/usr/bin/tar", ["-cf", archive.path, "-C", folder.path, source.lastPathComponent])
            try expect(packed.succeeded, "TAR fixture")
            try TarSafety.validate(archive)
            let output = folder.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await ArchiveEngine().extract(archive, format: .tar, into: output)
            try expectEqual(try String(contentsOf: output.appendingPathComponent("safe.txt"), encoding: .utf8), "safe")
            let gzipArchive = folder.appendingPathComponent("safe.tar.gz")
            let compressed = try await Shell.runToFile("/usr/bin/gzip", ["-c", archive.path], output: gzipArchive)
            try expect(compressed.succeeded, "TAR.GZ fixture")
            let gzipOutput = folder.appendingPathComponent("gzip output")
            try FileManager.default.createDirectory(at: gzipOutput, withIntermediateDirectories: true)
            try await ArchiveEngine().extract(gzipArchive, format: .gz, into: gzipOutput)
            try expectEqual(try String(contentsOf: gzipOutput.appendingPathComponent("safe.txt"), encoding: .utf8), "safe")
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let linkArchive = folder.appendingPathComponent("link.tar")
            let linkPacked = try await Shell.run("/usr/bin/tar", ["-cf", linkArchive.path, "-C", folder.path, link.lastPathComponent])
            try expect(linkPacked.succeeded, "link TAR fixture")
            do {
                try TarSafety.validate(linkArchive)
                throw TestFailure(description: "TAR link was accepted")
            } catch is TestFailure {
                throw TestFailure(description: "TAR link was accepted")
            } catch {}
        }

        runner.test("duplicate names do not replace originals") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let original = folder.appendingPathComponent("report.txt")
            try Data("original".utf8).write(to: original)
            let first = FileActionRunner.duplicateDestination(for: original)
            try expectEqual(first.lastPathComponent, "report copy.txt")
            try Data("earlier copy".utf8).write(to: first)
            let second = FileActionRunner.duplicateDestination(for: original)
            try expectEqual(second.lastPathComponent, "report copy 2.txt")
            try expectEqual(String(data: try Data(contentsOf: original), encoding: .utf8), "original")
        }

        runner.test("operation history persists outcomes and newest-first order") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("history.json")
            let first = JobRecord(id: UUID(), date: Date(), title: "Converting", detail: "a.txt", outcome: .done, outputs: [folder.appendingPathComponent("a.pdf")], error: nil)
            let second = JobRecord(id: UUID(), date: Date(), title: "Extracting", detail: "bad.zip", outcome: .failed, outputs: [], error: "Unsafe ZIP")
            _ = try JobHistory.append(first, to: path)
            let records = try JobHistory.append(second, to: path)
            try expectEqual(records.map(\.id), [second.id, first.id])
            try expectEqual(JobHistory.load(from: path), records)
        }

        runner.test("operation history can remove entries and retains only 50") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("history.json")
            let output = folder.appendingPathComponent("keep.pdf")
            try Data("keep".utf8).write(to: output)
            var ids: [UUID] = []
            for number in 0..<52 {
                let id = UUID()
                ids.append(id)
                let record = JobRecord(id: id, date: Date(), title: "Job \(number)", detail: "input.txt", outcome: .done, outputs: [output], error: nil)
                _ = try JobHistory.append(record, to: path)
            }
            try expectEqual(JobHistory.load(from: path).count, 50)
            try expectEqual(JobHistory.load(from: path).first?.id, ids[51])
            try expectEqual(JobHistory.load(from: path).last?.id, ids[2])
            let remaining = try JobHistory.remove(ids: [ids[51]], from: path)
            try expectEqual(remaining.count, 49)
            try expectEqual(remaining.first?.id, ids[50])
            try expectEqual(try JobHistory.clear(from: path).count, 0)
            try expectEqual(JobHistory.load(from: path).count, 0)
            try expectEqual(try Data(contentsOf: output), Data("keep".utf8))
        }

        runner.test("loading old history compacts the saved file") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("history.json")
            let legacy = (0..<55).map { number in
                JobRecord(id: UUID(), date: Date(), title: "Job \(number)", detail: "input.txt", outcome: .done, outputs: [], error: nil)
            }
            try JSONEncoder().encode(legacy).write(to: path)
            let retained = JobHistory.load(from: path)
            try expectEqual(retained.count, 50)
            try expectEqual(retained.first?.id, legacy.first?.id)
            try expectEqual(retained.last?.id, legacy[49].id)
            let onDisk = try JSONDecoder().decode([JobRecord].self, from: Data(contentsOf: path))
            try expectEqual(onDisk, retained)
        }

        runner.test("media exporter never removes an occupied destination") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appendingPathComponent("original.mov")
            let bytes = Data("keep this".utf8)
            try bytes.write(to: output)
            do {
                try AVExporter.requireVacant(output)
                throw TestFailure(description: "occupied media output accepted")
            } catch is TestFailure {
                throw TestFailure(description: "occupied media output accepted")
            } catch {
                try expectEqual(try Data(contentsOf: output), bytes)
            }
        }

        await runner.testAsync("binary process output refuses occupied files") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appendingPathComponent("occupied.bin")
            let bytes = Data("unchanged".utf8)
            try bytes.write(to: output)
            do {
                _ = try await Shell.runToFile("/usr/bin/true", [], output: output)
                throw TestFailure(description: "binary output replaced occupied file")
            } catch is TestFailure {
                throw TestFailure(description: "binary output replaced occupied file")
            } catch {
                try expectEqual(try Data(contentsOf: output), bytes)
            }
        }

        await runner.testAsync("cancelled queue wait releases promptly without taking a slot") {
            let semaphore = AsyncSemaphore(limit: 1)
            try expect(await semaphore.wait(), "first job should acquire slot")
            let queued = Task { await semaphore.wait() }
            await Task.yield()
            queued.cancel()
            try expect(!(await queued.value), "cancelled waiter must return without a signal")
            await semaphore.signal()
            try expect(await semaphore.wait(), "next job should acquire released slot")
            await semaphore.signal()
        }

        await runner.testAsync("conversion never overwrites occupied output") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source.txt")
            let destination = folder.appendingPathComponent("source.srt")
            try Data("original".utf8).write(to: source)
            try Data("occupied".utf8).write(to: destination)
            let request = ConversionRequest(source: source, sourceFormat: .txt, target: .srt, destination: destination, progress: { _ in })
            do {
                _ = try await Engines.convert(request, using: TestConversionEngine(behavior: .write))
                throw TestFailure(description: "conversion unexpectedly replaced occupied output")
            } catch is TestFailure {
                throw TestFailure(description: "conversion unexpectedly replaced occupied output")
            } catch {}
            try expectEqual(String(data: try Data(contentsOf: destination), encoding: .utf8), "occupied")
            try expectEqual(String(data: try Data(contentsOf: source), encoding: .utf8), "original")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        }

        await runner.testAsync("failed and cancelled conversions remove staged output") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source.txt")
            let destination = folder.appendingPathComponent("source.srt")
            try Data("original".utf8).write(to: source)
            let request = ConversionRequest(source: source, sourceFormat: .txt, target: .srt, destination: destination, progress: { _ in })
            do {
                _ = try await Engines.convert(request, using: TestConversionEngine(behavior: .missingOutput))
                throw TestFailure(description: "missing output was reported as success")
            } catch is TestFailure {
                throw TestFailure(description: "missing output was reported as success")
            } catch {}
            do {
                _ = try await Engines.convert(request, using: TestConversionEngine(behavior: .emptyDirectory))
                throw TestFailure(description: "empty directory was reported as success")
            } catch is TestFailure {
                throw TestFailure(description: "empty directory was reported as success")
            } catch {}
            let task = Task { try await Engines.convert(request, using: TestConversionEngine(behavior: .waitForCancellation)) }
            try await Task.sleep(nanoseconds: 100_000_000)
            task.cancel()
            _ = try? await task.value
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["source.txt"])
        }

        runner.test("output writer preserves occupied files and cleans failures") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let destination = folder.appendingPathComponent("merged.pdf")
            try Data("occupied".utf8).write(to: destination)
            do {
                _ = try OutputWriter.write(to: destination) { staged in
                    try Data("new result".utf8).write(to: staged)
                }
                throw TestFailure(description: "occupied output was replaced")
            } catch is TestFailure {
                throw TestFailure(description: "occupied output was replaced")
            } catch {}
            try expectEqual(String(data: try Data(contentsOf: destination), encoding: .utf8), "occupied")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["merged.pdf"])
            do {
                _ = try OutputWriter.write(to: folder.appendingPathComponent("failed.pdf")) { staged in
                    try Data("partial".utf8).write(to: staged)
                    throw SatsumaError.cancelled
                }
                throw TestFailure(description: "failed output was published")
            } catch is TestFailure {
                throw TestFailure(description: "failed output was published")
            } catch {}
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["merged.pdf"])
        }

        runner.test("out-of-space write failure leaves no published or staged output") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source.txt")
            let original = Data("keep original".utf8)
            try original.write(to: source)
            let destination = folder.appendingPathComponent("source.pdf")
            do {
                _ = try OutputWriter.write(to: destination) { staged in
                    try Data("partial".utf8).write(to: staged)
                    throw POSIXError(.ENOSPC)
                }
                throw TestFailure(description: "out-of-space write was reported as success")
            } catch let error as POSIXError where error.code == .ENOSPC {
                // A partial file can exist briefly, but must not survive the failure.
            }
            try expectEqual(try Data(contentsOf: source), original)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["source.txt"])
        }

        runner.test("PDF split publishes a complete new folder") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source.pdf")
            try TextRenderer.writePDF("First page", to: source)
            let destination = folder.appendingPathComponent("source pages", isDirectory: true)
            let published = try OutputWriter.writeDirectory(to: destination) { staged in
                _ = try PDFOps.split(source, mode: .everyPage, every: 1, ranges: "", into: staged)
            }
            let files = try FileManager.default.contentsOfDirectory(at: published, includingPropertiesForKeys: nil)
            try expectEqual(files.count, 1)
            try expectEqual(PDFDocument(url: files[0])?.pageCount, 1)
            try expectEqual(PDFDocument(url: source)?.pageCount, 1)
        }

        runner.test("PDF merge preserves input order and source documents") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let first = folder.appendingPathComponent("first.pdf")
            let second = folder.appendingPathComponent("second.pdf")
            let merged = folder.appendingPathComponent("merged.pdf")
            try TextRenderer.writePDF("First document", to: first)
            try TextRenderer.writePDF("Second document", to: second)
            let firstBytes = try Data(contentsOf: first)
            let secondBytes = try Data(contentsOf: second)
            let published = try OutputWriter.write(to: merged) { staged in
                try PDFOps.merge([second, first], to: staged)
            }
            guard let document = PDFDocument(url: published) else {
                throw TestFailure(description: "Merged PDF could not be opened")
            }
            try expectEqual(document.pageCount, 2)
            try expect(document.page(at: 0)?.string?.contains("Second document") == true, "PDF merge changed input order")
            try expect(document.page(at: 1)?.string?.contains("First document") == true, "PDF merge changed input order")
            try expectEqual(try Data(contentsOf: first), firstBytes)
            try expectEqual(try Data(contentsOf: second), secondBytes)
        }

        runner.test("empty PDF merge fails without publishing output") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let destination = folder.appendingPathComponent("empty.pdf")
            do {
                _ = try OutputWriter.write(to: destination) { staged in
                    try PDFOps.merge([], to: staged)
                }
                throw TestFailure(description: "Empty merge succeeded")
            } catch is TestFailure {
                throw TestFailure(description: "Empty merge succeeded")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: destination.path), "Empty merge left output")
                try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Empty merge left staged files")
            }
        }

        runner.test("strong PDF compression keeps every page and the original") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let first = folder.appendingPathComponent("first.pdf")
            let second = folder.appendingPathComponent("second.pdf")
            let source = folder.appendingPathComponent("source.pdf")
            let destination = folder.appendingPathComponent("compressed.pdf")
            try TextRenderer.writePDF("First page", to: first)
            try TextRenderer.writePDF("Second page", to: second)
            try PDFOps.merge([first, second], to: source)
            let originalBytes = try Data(contentsOf: source)
            _ = try OutputWriter.write(to: destination) { staged in
                try PDFOps.compress(source, strong: true, to: staged)
            }
            let sourceDocument = try PDFOps.document(source)
            let compressedDocument = try PDFOps.document(destination)
            try expectEqual(compressedDocument.pageCount, 2)
            for index in 0..<2 {
                let originalBounds = sourceDocument.page(at: index)!.bounds(for: .mediaBox)
                let compressedBounds = compressedDocument.page(at: index)!.bounds(for: .mediaBox)
                try expectEqual(compressedBounds.size, originalBounds.size, "strong compression must retain page size")
            }
            try expectEqual(try Data(contentsOf: source), originalBytes)
        }

        runner.test("PDF page edits reorder and rotate without silently dropping missing pages") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let first = folder.appendingPathComponent("first.pdf")
            let second = folder.appendingPathComponent("second.pdf")
            try TextRenderer.writePDF("First page", to: first)
            try TextRenderer.writePDF("Second page", to: second)
            let firstBytes = try Data(contentsOf: first)
            let secondBytes = try Data(contentsOf: second)
            let destination = folder.appendingPathComponent("organized.pdf")
            let pages = [
                PDFPageRef(sourceIndex: 0, rotation: 90, sourceURL: second),
                PDFPageRef(sourceIndex: 0, rotation: 0, sourceURL: first),
            ]
            _ = try OutputWriter.write(to: destination) { staged in
                try PDFOps.assemble(pages: pages, to: staged)
            }
            guard let organized = PDFDocument(url: destination) else { throw TestFailure(description: "Could not open organized PDF") }
            try expectEqual(organized.pageCount, 2)
            try expect(organized.page(at: 0)?.string?.contains("Second page") == true, "Pages were not reordered")
            try expectEqual(organized.page(at: 0)?.rotation, 90)
            try expect(organized.page(at: 1)?.string?.contains("First page") == true, "Pages were not reordered")
            let invalid = folder.appendingPathComponent("invalid.pdf")
            do {
                _ = try OutputWriter.write(to: invalid) { staged in
                    try PDFOps.assemble(pages: [PDFPageRef(sourceIndex: 9, rotation: 0, sourceURL: first)], to: staged)
                }
                throw TestFailure(description: "Missing PDF page was silently dropped")
            } catch is TestFailure {
                throw TestFailure(description: "Missing PDF page was silently dropped")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: invalid.path), "Failed edit left a PDF output")
            }
            try expectEqual(try Data(contentsOf: first), firstBytes)
            try expectEqual(try Data(contentsOf: second), secondBytes)
        }

        runner.test("solid image redaction renders an opaque copy") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
            guard let originalImage = ImageToolSupport.cgImage(source) else {
                throw TestFailure(description: "Could not render source image")
            }
            let original = folder.appendingPathComponent("original.png")
            let destination = folder.appendingPathComponent("original redacted.png")
            try ImageIOBridge.write(originalImage, to: original, format: .png)
            let originalBytes = try Data(contentsOf: original)
            let redaction = Redaction(rect: CGRect(x: 4, y: 4, width: 8, height: 8))
            _ = try OutputWriter.write(to: destination) { staged in
                let result = ImageOps.redact(source, redactions: [redaction])
                guard let image = ImageToolSupport.cgImage(result) else {
                    throw TestFailure(description: "Could not render redaction")
                }
                try ImageIOBridge.write(image, to: staged, format: .png)
            }
            let saved = try ImageIOBridge.load(destination)
            let context = CIContext(options: [.useSoftwareRenderer: true])
            var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                context.render(CIImage(cgImage: saved), toBitmap: bytes.baseAddress!, rowBytes: 16 * 4,
                               bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            let covered = (8 * 16 + 8) * 4
            let uncovered = (1 * 16 + 1) * 4
            try expectEqual(Array(pixels[covered..<(covered + 4)]), [0, 0, 0, 255])
            try expect(pixels[uncovered] > 240 && pixels[uncovered + 3] == 255, "Uncovered pixels must remain opaque red")
            try expectEqual(try Data(contentsOf: original), originalBytes)
        }

        runner.test("blur and pixelation strength change rendered redactions") {
            var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
            for y in 0..<96 {
                for x in 0..<96 {
                    let offset = (y * 96 + x) * 4
                    pixels[offset] = UInt8(x * 2)
                    pixels[offset + 1] = UInt8(y * 2)
                    pixels[offset + 2] = UInt8((x + y) % 96 * 2)
                }
            }
            let input = CIImage(bitmapData: Data(pixels), bytesPerRow: 96 * 4,
                                size: CGSize(width: 96, height: 96), format: .RGBA8,
                                colorSpace: CGColorSpaceCreateDeviceRGB())
            var redaction = Redaction(rect: CGRect(x: 0, y: 0, width: 96, height: 96))
            for style in [RedactionStyle.blur, .pixelate] {
                redaction.style = style
                redaction.strength = 1
                let low = ImageOps.redact(input, redactions: [redaction])
                redaction.strength = 6
                let high = ImageOps.redact(input, redactions: [redaction])
                guard let lowImage = ImageToolSupport.cgImage(low), let highImage = ImageToolSupport.cgImage(high),
                      let lowData = lowImage.dataProvider?.data, let highData = highImage.dataProvider?.data else {
                    throw TestFailure(description: "Could not render \(style.rawValue) samples")
                }
                try expect(lowData != highData, "Stronger \(style.rawValue) must change the exported pixels")
            }
        }

        runner.test("Vision suggestions map bottom-origin boxes to image coordinates") {
            let rect = RedactionSuggestions.imageRect(from: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                                      size: CGSize(width: 1000, height: 500))
            try expect(abs(rect.minX - 100) < 0.001 && abs(rect.minY - 200) < 0.001 &&
                       abs(rect.width - 300) < 0.001 && abs(rect.height - 200) < 0.001,
                       "Vision box must map to top-origin image coordinates")
        }

        runner.test("Vision suggests visible text areas locally") {
            let image = NSImage(size: CGSize(width: 800, height: 180))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 800, height: 180).fill()
            ("CONFIDENTIAL DOCUMENT" as NSString).draw(
                at: CGPoint(x: 20, y: 45),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 60), .foregroundColor: NSColor.black]
            )
            image.unlockFocus()
            guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw TestFailure(description: "Could not render text fixture")
            }
            let suggestions = try RedactionSuggestions.detect(.text, in: bitmap)
            try expect(!suggestions.isEmpty, "Vision did not detect the visible text")
            let bounds = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
            try expect(suggestions.allSatisfy { bounds.contains($0) },
                       "Suggested text area escaped the image")
        }

        runner.test("OCR copy is temporary and image export adds a searchable PDF text layer") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("scan.png")
            let destination = folder.appendingPathComponent("scan searchable.pdf")
            let image = NSImage(size: CGSize(width: 900, height: 220))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 900, height: 220).fill()
            ("SEARCHABLE PAPER SAMPLE" as NSString).draw(at: CGPoint(x: 20, y: 65),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black])
            image.unlockFocus()
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                throw TestFailure(description: "Could not create scanned-image fixture")
            }
            try png.write(to: source)
            let original = try Data(contentsOf: source)
            let text = try SearchablePDF.extractText(from: source)
            try expect(text.contains("SEARCHABLE"), "Vision did not recognize the scanned image")
            let visualScan = try SearchablePDF.scanPages(from: source)
            try expectEqual(visualScan.count, 1)
            try expect(visualScan[0].lines.contains { $0.text.contains("SEARCHABLE") }, "Selectable overlay lost OCR lines")
            try expect(visualScan[0].lines.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.normalizedBox) },
                       "Selectable OCR text escaped image bounds")
            try expect(visualScan[0].lines.allSatisfy { (0...1).contains($0.confidence) },
                       "OCR confidence was outside Vision's expected range")
            let uncertain = SearchablePDF.ScannedPage(number: 1, text: "unclear", lines: [
                .init(text: "unclear", normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.59),
                .init(text: "clear", normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.6)
            ])
            try expectEqual(uncertain.uncertainLineCount, 1)
            let display = try SearchablePDF.displayImage(from: source, pageIndex: 0)
            try expect(display.size.width > display.size.height, "Wide image preview lost its aspect ratio")
            let canvas = OCRImageCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
            canvas.configure(image: display, lines: visualScan[0].lines, query: "SEARCHABLE")
            canvas.layoutSubtreeIfNeeded()
            let characters = canvas.selectableCharacters
            guard let wordIndex = characters.indices.first(where: { index in
                Array(characters[index...].prefix(10)).joined() == "SEARCHABLE"
            }), let fittedFrame = canvas.tokenFrame(at: wordIndex) else {
                throw TestFailure(description: "OCR preview has no bounded SEARCHABLE letters")
            }
            let selectionWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                                           styleMask: .borderless, backing: .buffered, defer: false)
            selectionWindow.contentView = canvas
            selectionWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            selectionWindow.orderFrontRegardless()
            defer { selectionWindow.orderOut(nil) }
            canvas.frame = selectionWindow.contentView!.bounds
            canvas.layoutSubtreeIfNeeded()
            guard let wordFrame = canvas.tokenFrame(at: wordIndex),
                  let click = NSEvent.mouseEvent(with: .leftMouseDown,
                      location: canvas.convert(CGPoint(x: wordFrame.midX, y: wordFrame.midY), to: nil),
                      modifierFlags: [], timestamp: 0, windowNumber: selectionWindow.windowNumber,
                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw TestFailure(description: "Could not synthesize a word-selection click")
            }
            selectionWindow.sendEvent(click)
            try expectEqual(canvas.selectedText, "S")
            if let lastIndex = characters.indices.last(where: { index in
                index >= 5 && Array(characters[(index - 5)...index]).joined() == "SAMPLE"
            }) {
                guard let lastFrame = canvas.tokenFrame(at: lastIndex),
                      let drag = NSEvent.mouseEvent(with: .leftMouseDragged,
                          location: canvas.convert(CGPoint(x: lastFrame.midX, y: lastFrame.midY), to: nil),
                          modifierFlags: [], timestamp: 0.1, windowNumber: selectionWindow.windowNumber,
                          context: nil, eventNumber: 2, clickCount: 1, pressure: 1) else {
                    throw TestFailure(description: "Could not synthesize a multi-word selection drag")
                }
                selectionWindow.sendEvent(drag)
                try expectEqual(canvas.selectedText, "SEARCHABLE PAPER SAMPLE")
                canvas.selectToken(at: wordIndex)
            }
            canvas.selectToken(at: wordIndex + 2)
            canvas.selectThroughToken(at: wordIndex + 5)
            try expectEqual(canvas.selectedText, "ARCH", "partial OCR selection must copy only highlighted letters")
            canvas.selectToken(at: wordIndex)
            canvas.frame = NSRect(x: 0, y: 0, width: 1800, height: 600)
            canvas.needsLayout = true
            canvas.layoutSubtreeIfNeeded()
            try expect((canvas.tokenFrame(at: wordIndex)?.width ?? 0) > fittedFrame.width * 1.8,
                       "zooming the OCR canvas did not enlarge selectable text regions")
            try expectEqual(canvas.selectedText, "S")
            let zoomView = OCRMagnifyingScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            zoomView.allowsMagnification = true
            zoomView.minMagnification = 1
            zoomView.maxMagnification = 4
            zoomView.documentView = OCRImageCanvas(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            zoomView.sizeDocumentToViewport()
            zoomView.setMagnification(2, centeredAt: NSPoint(x: 150, y: 100))
            let centered = zoomView.contentView.documentVisibleRect
            try expect(abs(centered.midX - 150) < 4 && abs(centered.midY - 100) < 4,
                       "OCR zoom did not retain its chosen center")
            try expect(!FileManager.default.fileExists(atPath: destination.path), "copy-only scan wrote a PDF")
            let published = try OutputWriter.write(to: destination) { staged in
                try SearchablePDF.create(from: source, to: staged)
            }
            guard let pdf = PDFDocument(url: published) else { throw TestFailure(description: "Could not reopen OCR PDF") }
            try expectEqual(pdf.pageCount, 1)
            try expect(pdf.string?.contains("SEARCHABLE") == true, "PDF text layer is not searchable")
            let expectedPageSize = CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
            try expectEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, expectedPageSize)
            guard let rendered = pdf.page(at: 0)?.thumbnail(of: CGSize(width: 900, height: 220), for: .mediaBox),
                  let renderedCG = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw TestFailure(description: "Could not render searchable PDF")
            }
            let pixels = NSBitmapImageRep(cgImage: renderedCG)
            let rightStart = Int(Double(pixels.pixelsWide) * 0.70)
            let rightEnd = Int(Double(pixels.pixelsWide) * 0.95)
            let visibleRightText = (rightStart..<rightEnd).contains { x in
                (0..<pixels.pixelsHigh).contains { y in
                    guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent < 0.35 && color.greenComponent < 0.35 && color.blueComponent < 0.35
                }
            }
            try expect(visibleRightText, "The right side of the scanned image was cropped from the PDF")
            try expectEqual(try Data(contentsOf: source), original, "OCR changed the image source")
            let nextName = ConversionMatrix.uniqueURL(directory: folder, baseName: "scan", suffix: "searchable", ext: "pdf")
            try expectEqual(nextName.lastPathComponent, "scan searchable 2.pdf")

            let scanned = PDFDocument()
            guard let picture = NSImage(contentsOf: source), let scannedPage = PDFPage(image: picture) else {
                throw TestFailure(description: "Could not create image-only PDF fixture")
            }
            scanned.insert(scannedPage, at: 0)
            let scannedURL = folder.appendingPathComponent("image-only.pdf")
            let scannedOutput = folder.appendingPathComponent("image-only searchable.pdf")
            try expect(scanned.write(to: scannedURL), "Could not write image-only PDF fixture")
            try expect((PDFDocument(url: scannedURL)?.string ?? "").isEmpty, "Fixture was already searchable")
            let scannedBytes = try Data(contentsOf: scannedURL)
            try SearchablePDF.create(from: scannedURL, to: scannedOutput)
            try expect(PDFDocument(url: scannedOutput)?.string?.contains("SEARCHABLE") == true,
                       "image-only PDF did not gain searchable text")
            try expectEqual(PDFDocument(url: scannedOutput)?.page(at: 0)?.bounds(for: .mediaBox).size,
                            PDFDocument(url: scannedURL)?.page(at: 0)?.bounds(for: .mediaBox).size)
            try expectEqual(try Data(contentsOf: scannedURL), scannedBytes, "image-only PDF source changed")

            let tallImage = NSImage(size: CGSize(width: 300, height: 500))
            tallImage.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 300, height: 500).fill()
            tallImage.unlockFocus()
            guard let firstPage = PDFPage(image: picture), let tallPage = PDFPage(image: tallImage) else {
                throw TestFailure(description: "Could not create mixed-size PDF pages")
            }
            let mixed = PDFDocument()
            mixed.insert(firstPage, at: 0)
            mixed.insert(tallPage, at: 1)
            let mixedSource = folder.appendingPathComponent("mixed-pages.pdf")
            let mixedOutput = folder.appendingPathComponent("mixed-pages searchable.pdf")
            try expect(mixed.write(to: mixedSource), "Could not write mixed-size PDF fixture")
            try SearchablePDF.create(from: mixedSource, to: mixedOutput)
            let rebuilt = PDFDocument(url: mixedOutput)
            try expectEqual(rebuilt?.pageCount, 2)
            for index in 0..<2 {
                try expectEqual(rebuilt?.page(at: index)?.bounds(for: .mediaBox).size,
                                mixed.page(at: index)?.bounds(for: .mediaBox).size,
                                "Searchable export changed page \(index + 1) dimensions")
            }
        }

        await runner.testAsync("cancelled searchable-PDF export leaves no output") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source.pdf")
            let destination = folder.appendingPathComponent("source searchable.pdf")
            try TextRenderer.writePDF("CANCELLATION SAMPLE", to: source)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try OutputWriter.write(to: destination) { staged in
                    try SearchablePDF.create(from: source, to: staged)
                }
            }
            do {
                _ = try await task.value
                throw TestFailure(description: "cancelled OCR export succeeded")
            } catch is TestFailure { throw TestFailure(description: "cancelled OCR export succeeded") }
            catch {}
            try expect(!FileManager.default.fileExists(atPath: destination.path), "cancelled OCR export published output")
        }

        runner.test("searchable PDF keeps native text and rejects annotated pages") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source.pdf")
            let output = folder.appendingPathComponent("source searchable.pdf")
            try TextRenderer.writePDF("EXISTING SEARCHABLE TEXT", to: source)
            let original = try Data(contentsOf: source)
            let nativeScan = try SearchablePDF.scanPages(from: source)
            try expect(nativeScan.first?.text.contains("EXISTING SEARCHABLE TEXT") == true,
                       "Native PDF text was not available in the scan")
            try expect(nativeScan.first?.lines.contains { $0.text.contains("SEARCHABLE") } == true,
                       "Native PDF text was not selectable over its page preview")
            try expect(nativeScan.first?.lines.flatMap(\.words).contains { $0.text == "SEARCHABLE" } == true,
                       "Native PDF text did not expose word-sized selection boxes")
            let nativeCanvas = OCRImageCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            nativeCanvas.configure(image: try SearchablePDF.displayImage(from: source, pageIndex: 0),
                                   lines: nativeScan[0].lines, query: "")
            nativeCanvas.layoutSubtreeIfNeeded()
            let nativeCharacters = nativeCanvas.selectableCharacters
            guard let nativeWordIndex = nativeCharacters.indices.first(where: { index in
                Array(nativeCharacters[index...].prefix(10)).joined() == "SEARCHABLE"
            }) else {
                throw TestFailure(description: "Native PDF letters were not selectable in the preview")
            }
            nativeCanvas.selectToken(at: nativeWordIndex)
            nativeCanvas.selectThroughToken(at: nativeWordIndex + 9)
            try expectEqual(nativeCanvas.selectedText, "SEARCHABLE")
            nativeCanvas.selectToken(at: nativeWordIndex + 2)
            nativeCanvas.selectThroughToken(at: nativeWordIndex + 5)
            try expectEqual(nativeCanvas.selectedText, "ARCH")
            try SearchablePDF.create(from: source, to: output)
            let result = PDFDocument(url: output)
            try expectEqual(result?.pageCount, 1)
            try expect(result?.string?.contains("EXISTING SEARCHABLE TEXT") == true,
                       "existing selectable text was lost")
            try expectEqual(try Data(contentsOf: source), original, "PDF source changed")
            guard let document = PDFDocument(url: source), let page = document.page(at: 0) else {
                throw TestFailure(description: "Could not reopen annotated fixture")
            }
            page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 20), forType: .freeText, withProperties: nil))
            try expect(document.write(to: source), "Could not save annotated fixture")
            let unsafeOutput = folder.appendingPathComponent("annotated searchable.pdf")
            do {
                _ = try OutputWriter.write(to: unsafeOutput) { staged in
                    try SearchablePDF.create(from: source, to: staged)
                }
                throw TestFailure(description: "annotated PDF was silently flattened")
            } catch is TestFailure { throw TestFailure(description: "annotated PDF was silently flattened") }
            catch {}
            try expect(!FileManager.default.fileExists(atPath: unsafeOutput.path), "annotated PDF left an output")
            let locked = folder.appendingPathComponent("locked.pdf")
            guard let plain = PDFDocument(url: output) else { throw TestFailure(description: "Could not create protected fixture") }
            try expect(plain.write(to: locked, withOptions: [.userPasswordOption: "ocr-test-password",
                                                      .ownerPasswordOption: "ocr-owner-password"]),
                       "Could not write protected fixture")
            let lockedOutput = folder.appendingPathComponent("locked searchable.pdf")
            do {
                _ = try OutputWriter.write(to: lockedOutput) { staged in
                    try SearchablePDF.create(from: locked, to: staged)
                }
                throw TestFailure(description: "protected PDF was processed")
            } catch is TestFailure { throw TestFailure(description: "protected PDF was processed") }
            catch {}
            try expect(!FileManager.default.fileExists(atPath: lockedOutput.path), "protected PDF left an output")
        }

        runner.test("multiple images create readable PDF pages without changing inputs") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let red = folder.appendingPathComponent("red.png")
            let blue = folder.appendingPathComponent("blue.png")
            let colors: [(URL, CIColor)] = [(red, CIColor(red: 1, green: 0, blue: 0)), (blue, CIColor(red: 0, green: 0, blue: 1))]
            for (url, color) in colors {
                let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
                guard let cg = ImageToolSupport.cgImage(image) else { throw TestFailure(description: "Could not make image fixture") }
                try ImageIOBridge.write(cg, to: url, format: .png)
            }
            let originalBytes = try [red, blue].map { try Data(contentsOf: $0) }
            let fit = folder.appendingPathComponent("fit.pdf")
            let letter = folder.appendingPathComponent("letter.pdf")
            _ = try OutputWriter.write(to: fit) { staged in
                try PDFOps.fromImages([blue, red], to: staged, progress: { _ in })
            }
            _ = try OutputWriter.write(to: letter) { staged in
                try PDFRenderer.writeImagesPDF([red, blue], pageSize: CGSize(width: 612, height: 792), to: staged, progress: { _ in })
            }
            for output in [fit, letter] {
                guard let document = PDFDocument(url: output) else { throw TestFailure(description: "Could not read created PDF") }
                try expectEqual(document.pageCount, 2)
            }
            try expectEqual(PDFDocument(url: letter)?.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
            try expectEqual(try [red, blue].map { try Data(contentsOf: $0) }, originalBytes)
        }

        await runner.testAsync("real local image and document conversions produce readable copies") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let original = folder.appendingPathComponent("study notes.txt")
            let pdf = folder.appendingPathComponent("study notes.pdf")
            try Data("ZeroClick local conversion".utf8).write(to: original)
            let documentRequest = ConversionRequest(source: original, sourceFormat: .txt, target: .pdf, destination: pdf, progress: { _ in })
            let publishedPDF = try await Engines.convert(documentRequest)
            try expectEqual(publishedPDF, pdf)
            try expect((PDFDocument(url: publishedPDF)?.pageCount ?? 0) > 0, "PDF must be readable")
            try expectEqual(String(data: try Data(contentsOf: original), encoding: .utf8), "ZeroClick local conversion")
            let markdown = folder.appendingPathComponent("study notes.md")
            let markdownRequest = ConversionRequest(source: publishedPDF, sourceFormat: .pdf, target: .md, destination: markdown, progress: { _ in })
            let publishedMarkdown = try await Engines.convert(markdownRequest)
            try expectEqual(publishedMarkdown, markdown)
            try expect(try String(contentsOf: publishedMarkdown, encoding: .utf8).contains("ZeroClick local conversion"), "PDF text must survive Markdown export")

            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let image = bitmap.cgImage else {
                throw TestFailure(description: "Could not make sample image")
            }
            let png = folder.appendingPathComponent("sample.png")
            let jpg = folder.appendingPathComponent("sample.jpg")
            try ImageIOBridge.write(image, to: png, format: .png)
            let imageRequest = ConversionRequest(source: png, sourceFormat: .png, target: .jpg, destination: jpg, progress: { _ in })
            _ = try await Engines.convert(imageRequest)
            try expectEqual(FileFormat.detect(jpg), .jpg)
            try expect(ImageIOBridge.pixelSize(jpg).width > 0, "JPEG must be readable")
            try expectEqual(FileFormat.detect(png), .png)
        }

        await runner.testAsync("read-only Unicode source converts without changing its bytes") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("café 学習 notes.txt")
            let destination = folder.appendingPathComponent("café 学習 notes.pdf")
            let bytes = Data("Local study notes with Unicode filename".utf8)
            try bytes.write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
            let request = ConversionRequest(source: source, sourceFormat: .txt, target: .pdf, destination: destination, progress: { _ in })
            let published = try await Engines.convert(request)
            try expectEqual(published, destination)
            try expectEqual(PDFDocument(url: published)?.pageCount, 1)
            try expectEqual(try Data(contentsOf: source), bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            try expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        }

        await runner.testAsync("HEIC converts to a readable PNG while preserving the original") {
            guard ImageIOBridge.canEncodeNatively(.heic) else {
                throw TestFailure(description: "Native HEIC encoder unavailable on this Mac")
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("photo.heic")
            let destination = folder.appendingPathComponent("photo.png")
            let colored = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.8))
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            guard let image = ImageToolSupport.cgImage(colored) else {
                throw TestFailure(description: "Could not render HEIC fixture")
            }
            try ImageIOBridge.write(image, to: source, format: .heic)
            let originalBytes = try Data(contentsOf: source)
            let request = ConversionRequest(source: source, sourceFormat: .heic, target: .png, destination: destination, progress: { _ in })
            _ = try await Engines.convert(request)
            try expectEqual(FileFormat.detect(destination), .png)
            try expectEqual(ImageIOBridge.pixelSize(destination), CGSize(width: 64, height: 64))
            try expectEqual(try Data(contentsOf: source), originalBytes)
        }

        runner.test("large SVG preview respects its pixel limit") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("large.svg")
            try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10000\" height=\"5000\"><rect width=\"10000\" height=\"5000\" fill=\"red\"/></svg>"
                .write(to: source, atomically: true, encoding: .utf8)
            let preview = try ImageIOBridge.load(source, maxPixelSize: 320)
            try expect(preview.width <= 320 && preview.height <= 320, "SVG preview exceeded pixel limit")
            try expect(preview.width > 0 && preview.height > 0, "SVG preview is empty")
        }

        await runner.testAsync("image compression and metadata removal create new readable files") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let image = bitmap.cgImage else {
                throw TestFailure(description: "Could not make sample image")
            }
            let original = folder.appendingPathComponent("photo.png")
            let compressedFormat = Compressor.outputFormat(for: original)
            let compressed = folder.appendingPathComponent("photo compressed.\(compressedFormat.fileExtension)")
            let clean = folder.appendingPathComponent("photo clean.png")
            try ImageIOBridge.write(image, to: original, format: .png)
            _ = try await OutputWriter.writeAsync(to: compressed) { staged in
                try await Compressor.compress(original, preset: .balanced, resizeLongEdge: 0, targetBytes: nil, to: staged, progress: { _ in })
            }
            _ = try await OutputWriter.writeAsync(to: clean) { staged in
                try await MetadataOps.write(original, edits: [], removeAll: true, removeSensitive: true, to: staged, progress: { _ in })
            }
            try expect(FileFormat.detect(compressed) == compressedFormat, "compressed signature \(Array((try Data(contentsOf: compressed)).prefix(12))) does not match \(compressedFormat)")
            try expectEqual(FileFormat.detect(clean), .png)
            try expectEqual(FileFormat.detect(original), .png)
            try expect(ImageIOBridge.pixelSize(compressed).width > 0 && ImageIOBridge.pixelSize(clean).width > 0, "Outputs must decode")
        }

        runner.test("no format converts to itself") {
            for format in FileFormat.allCases {
                try expect(!ConversionMatrix.targets(for: format).contains(format), "\(format) targets itself")
            }
        }

        runner.test("JPG and PNG export DOCX, other images do not") {
            try expect(ConversionMatrix.targets(for: .jpg).contains(.docx), "jpg → docx")
            try expect(ConversionMatrix.targets(for: .png).contains(.docx), "png → docx")
            try expect(!ConversionMatrix.targets(for: .webp).contains(.docx), "webp → docx")
            try expect(ConversionMatrix.targets(for: .svg).contains(.pdf), "svg → pdf")
        }

        runner.test("video exports GIF and MP3, GIF does not") {
            try expect(ConversionMatrix.targets(for: .mp4).contains(.gif), "mp4 → gif")
            try expect(ConversionMatrix.targets(for: .mp4).contains(.mp3), "mp4 → mp3")
            try expect(!ConversionMatrix.targets(for: .gif).contains(.mp3), "gif → mp3")
            try expectEqual(ConversionMatrix.targets(for: .gif), FileFormat.video)
        }

        runner.test("PDF, TXT, subtitle and archive targets") {
            try expectEqual(ConversionMatrix.targets(for: .pdf), [.docx, .jpg, .png, .txt, .md])
            try expectEqual(ConversionMatrix.targets(for: .txt), [.pdf, .jpg, .png, .srt, .vtt])
            try expectEqual(ConversionMatrix.targets(for: .srt), [.vtt, .txt])
            try expectEqual(ConversionMatrix.targets(for: .zip), [.tar, .gz])
            try expectEqual(ConversionMatrix.targets(for: .docx), [.txt, .md])
        }

        runner.test("every offered conversion has an engine") {
            for source in FileFormat.allCases {
                for target in ConversionMatrix.targets(for: source) {
                    try expect(Engines.engine(from: source, to: target) != nil, "No engine for \(source) → \(target)")
                }
            }
        }

        await runner.testAsync("DOCX exports paragraphs as UTF-8 text") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("sample.docx")
            let output = folder.appendingPathComponent("sample.txt")
            let markdown = folder.appendingPathComponent("sample.md")
            try await DocxWriter.write(paragraphs: ["First & last", "Second line"], images: [], to: source)
            let request = ConversionRequest(source: source, sourceFormat: .docx, target: .txt, destination: output, progress: { _ in })
            try await DocumentEngine().convert(request)
            try expectEqual(try String(contentsOf: output, encoding: .utf8), "First & last\nSecond line")
            let markdownRequest = ConversionRequest(source: source, sourceFormat: .docx, target: .md, destination: markdown, progress: { _ in })
            try await DocumentEngine().convert(markdownRequest)
            try expectEqual(try String(contentsOf: markdown, encoding: .utf8), "First & last\n\nSecond line")
        }

        runner.test("mixed selection intersects targets") {
            try expectEqual(ConversionMatrix.targets(for: [.jpg, .webp]), [.png, .heic, .tiff, .avif, .bmp, .pdf])
            try expectEqual(ConversionMatrix.targets(for: [.jpg, .mp3]), [])
            try expectEqual(ConversionMatrix.targets(for: []), [])
        }

        runner.test("format detection from extension and aliases") {
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/Photo.JPEG")), .jpg)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.tif")), .tiff)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.tgz")), .gz)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.unknown")), nil)
        }

        runner.test("existing files reject misleading extensions") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let valid = directory.appendingPathComponent("valid.pdf")
            let disguised = directory.appendingPathComponent("disguised.png")
            try Data("%PDF-1.4\n".utf8).write(to: valid)
            try Data("%PDF-1.4\n".utf8).write(to: disguised)
            try expectEqual(FileFormat.detect(valid), .pdf)
            try expectEqual(FileFormat.detect(disguised), nil)
        }

        runner.test("stripped base names") {
            try expectEqual(ConversionMatrix.strippedBaseName("archive.tar.gz"), "archive")
            try expectEqual(ConversionMatrix.strippedBaseName("archive.tgz"), "archive")
            try expectEqual(ConversionMatrix.strippedBaseName("my.photo.HEIC"), "my.photo")
            try expectEqual(ConversionMatrix.strippedBaseName(".hidden"), ".hidden")
            try expectEqual(ConversionMatrix.strippedBaseName("noext"), "noext")
        }

        runner.test("output naming avoids collisions") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = URL(fileURLWithPath: "/tmp/photo.heic")
            let first = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir)
            try expectEqual(first.lastPathComponent, "photo.jpg")
            try Data().write(to: first)
            let second = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir)
            try expectEqual(second.lastPathComponent, "photo 2.jpg")
            let third = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir, existing: ["photo 2.jpg"])
            try expectEqual(third.lastPathComponent, "photo 3.jpg")
            let suffixed = ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "compressed", ext: "jpg")
            try expectEqual(suffixed.lastPathComponent, "photo compressed.jpg")
            try Data().write(to: suffixed)
            try expectEqual(ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "compressed", ext: "jpg").lastPathComponent, "photo compressed 2.jpg")
            try expectEqual(ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "", ext: "pdf").lastPathComponent, "photo.pdf")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("clip clips"), withIntermediateDirectories: true)
            try expectEqual(ConversionMatrix.uniqueDirectory(directory: dir, name: "clip clips").lastPathComponent, "clip clips 2")
            let unicode = URL(fileURLWithPath: "/tmp/café notes 📝.heic")
            let unicodeFirst = ConversionMatrix.outputURL(for: unicode, target: .jpg, in: dir)
            try expectEqual(unicodeFirst.lastPathComponent, "café notes 📝.jpg")
            try Data("occupied".utf8).write(to: unicodeFirst)
            try expectEqual(ConversionMatrix.outputURL(for: unicode, target: .jpg, in: dir).lastPathComponent, "café notes 📝 2.jpg")
        }

        runner.test("SRT parsing") {
            let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\nWorld\n\n2\n00:01:00,000 --> 00:01:03,250\n<i>Bye</i>\n"
            let cues = SubtitleParser.parse(srt, hint: .srt)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 1)
            try expectEqual(cues[0].end, 2.5)
            try expectEqual(cues[0].text, "Hello\nWorld")
            try expectEqual(cues[1].start, 60)
            try expectEqual(cues[1].end, 63.25)
        }

        runner.test("VTT parsing with header, notes and cue settings") {
            let vtt = "WEBVTT\nKind: captions\n\nNOTE comment\n\n00:01.000 --> 00:02.000 align:start\nFirst\n\n01:00:00.000 --> 01:00:01.000\nSecond\n"
            let cues = SubtitleParser.parse(vtt, hint: .vtt)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 1)
            try expectEqual(cues[0].end, 2)
            try expectEqual(cues[0].text, "First")
            try expectEqual(cues[1].start, 3600)
        }

        runner.test("subtitle serialization round trip") {
            let cues = [SubtitleCue(start: 0.5, end: 2, text: "A"), SubtitleCue(start: 3661.25, end: 3662, text: "B\nC")]
            let srt = SubtitleParser.serialize(cues, as: .srt)
            try expect(srt.hasPrefix("1\n00:00:00,500 --> 00:00:02,000\nA\n\n2\n01:01:01,250 --> 01:01:02,000\nB\nC\n"), "srt output: \(srt)")
            let vtt = SubtitleParser.serialize(cues, as: .vtt)
            try expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nA\n\n"), "vtt output: \(vtt)")
            let back = SubtitleParser.parse(vtt, hint: .vtt)
            try expectEqual(back.count, 2)
            try expectEqual(back[1].start, 3661.25)
            try expectEqual(SubtitleParser.serialize([SubtitleCue(start: 0, end: 1, text: "<b>x</b> {\\an8}y")], as: .txt), "x y\n")
        }

        runner.test("plain text becomes timed cues") {
            let cues = SubtitleParser.plainTextCues("One two three\n\nFour five")
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 0)
            try expect(cues[1].start == cues[0].end, "cues are contiguous")
            try expect(cues[0].end - cues[0].start >= 1.5, "minimum duration")
        }

        runner.test("timestamp parsing") {
            try expectEqual(SubtitleParser.parseTimestamp("00:00:01,500"), 1.5)
            try expectEqual(SubtitleParser.parseTimestamp("01:02.250"), 62.25)
            try expectEqual(SubtitleParser.parseTimestamp("5"), 5)
            try expectEqual(SubtitleParser.parseTimestamp("a:b"), nil)
            try expectEqual(TimeFormatter.parseClock("1:02.5"), 62.5)
            try expectEqual(TimeFormatter.clock(62.5), "1:02.50")
        }

        runner.test("PDF page range parsing") {
            try expectEqual(PDFOps.parseRanges("1-3, 5, 7-6, 12", pageCount: 10), [1...3, 5...5, 6...7])
            try expectEqual(PDFOps.parseRanges("-2, 8-", pageCount: 10), [1...2, 8...10])
            try expectEqual(PDFOps.parseRanges("abc", pageCount: 10), [])
        }

        runner.test("password-protected PDF unlock preserves the original and rejects wrong passwords") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let plain = folder.appendingPathComponent("plain.pdf")
            let locked = folder.appendingPathComponent("locked.pdf")
            let unlocked = folder.appendingPathComponent("locked unlocked.pdf")
            try TextRenderer.writePDF("Private test page", to: plain)
            let document = try PDFOps.document(plain)
            let options: [PDFDocumentWriteOption: Any] = [
                .userPasswordOption: "test-open-42",
                .ownerPasswordOption: "test-owner-42"
            ]
            try expect(document.write(to: locked, withOptions: options), "Could not create locked test PDF")
            let originalBytes = try Data(contentsOf: locked)
            guard let lockedDocument = PDFDocument(url: locked) else { throw TestFailure(description: "Could not reopen locked fixture") }
            try expect(lockedDocument.isEncrypted && lockedDocument.isLocked, "Fixture must require a password")
            let wheel = ActionRegistry.items(for: .actions, formats: [.pdf], urls: [locked])
            try expect(wheel.contains { $0.action == .tool(.unlockPDF) && $0.isEnabled }, "Protected PDF should enable Unlock")
            try expect(wheel.contains { $0.action == .tool(.encryptFile) && $0.isEnabled }, "Protected PDF should enable Encrypt")
            try expect(ActionRegistry.items(for: .tools, formats: [.pdf], urls: [locked]).contains { $0.action == .tool(.splitPDF) && !$0.isEnabled }, "Other PDF tools should remain visible but disabled for a protected PDF")
            let normalWheel = ActionRegistry.items(for: .actions, formats: [.pdf], urls: [plain])
            try expect(normalWheel.contains { $0.action == .tool(.unlockPDF) && !$0.isEnabled }, "Normal PDF must disable Unlock")
            do {
                _ = try OutputWriter.write(to: unlocked) { staged in
                    try PDFOps.unlock(locked, password: "wrong", to: staged)
                }
                throw TestFailure(description: "Wrong password succeeded")
            } catch is TestFailure {
                throw TestFailure(description: "Wrong password succeeded")
            } catch {
                try expect(!FileManager.default.fileExists(atPath: unlocked.path), "Wrong password left an output")
            }
            _ = try OutputWriter.write(to: unlocked) { staged in
                try PDFOps.unlock(locked, password: "test-open-42", to: staged)
            }
            guard let copy = PDFDocument(url: unlocked) else { throw TestFailure(description: "Could not reopen unlocked output") }
            try expect(!copy.isEncrypted && !copy.isLocked, "Output still requires password")
            try expectEqual(copy.pageCount, 1)
            try expect(copy.page(at: 0)?.string?.contains("Private test page") == true, "Page text was lost")
            try expectEqual(try Data(contentsOf: locked), originalBytes, "Source bytes changed")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3, "Unexpected staged files")
        }

        runner.test("tool applicability") {
            try expect(ToolID.cropImage.applies(to: [.jpg]), "crop single image")
            try expect(!ToolID.cropImage.applies(to: [.jpg, .png]), "crop needs one image")
            try expect(ToolID.createCollage.applies(to: [.jpg, .heic]), "collage multiple images")
            try expect(!ToolID.createCollage.applies(to: [.jpg]), "collage needs two")
            try expect(ToolID.compress.applies(to: [.pdf, .pdf]), "compress pdfs")
            try expect(!ToolID.compress.applies(to: [.jpg, .mp4]), "mixed categories")
            try expect(!ToolID.trimVideo.applies(to: [.gif]), "gif is not trimmable")
            try expect(ToolID.compress.applies(to: [.gif]), "gif compress")
            try expect(!ToolID.mergePDF.applies(to: [.docx, .docx]), "docx merge")
            try expectEqual(ToolID.available(for: [.mp3]).count, 8)
            try expectEqual(ToolID.available(for: [.pdf]).count, 7)
        }

        runner.test("compression presets") {
            try expect(CompressionPreset.strong.imageQuality < CompressionPreset.balanced.imageQuality, "strong is smaller")
            try expect(CompressionPreset.strong.videoBitrateFactor < CompressionPreset.balanced.videoBitrateFactor, "strong video")
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.svg")), .jpg)
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.jpg")), .jpg)
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.wav")), .m4a)
        }

        runner.test("FFmpeg timecode formatting") {
            try expectEqual(FFmpeg.timecode(3661.5), "01:01:01.500")
            try expectEqual(FFmpeg.timecode(0), "00:00:00.000")
        }

        runner.test("sf symbols resolve") {
            for tool in ToolID.allCases {
                try expect(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil, "\(tool.rawValue) symbol \(tool.symbol)")
            }
            for action in FileAction.allCases {
                try expect(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil, "\(action.rawValue) symbol \(action.symbol)")
            }
            for action in AIAction.allCases {
                try expect(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil, "\(action.rawValue) symbol \(action.symbol)")
            }
            for category in FormatCategory.allCases {
                try expect(NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil) != nil, "\(category.rawValue) symbol")
            }
        }

        runner.test("wheel action icons are distinct within each file category") {
            for format in FileFormat.allCases {
                for mode in [WheelMode.convert, .tools, .actions, .ai] {
                    let items = ActionRegistry.items(for: mode, formats: [format], ffmpegAvailable: true, bsdtarAvailable: true)
                    let keys = items.map { $0.iconBadge ?? $0.symbol }
                    try expectEqual(Set(keys).count, keys.count, "Duplicate icon in \(mode) for \(format)")
                }
            }
        }

        runner.test("narrow wedges use icons while wide wedges retain labels") {
            let longAction = RadialItem(fileAction: .openTerminal)
            let narrow = RadialGeometry(innerRadius: 59, outerRadius: 150, count: 18, quickCount: 3)
            let wide = RadialGeometry(innerRadius: 82, outerRadius: 210, count: 6, quickCount: 3)
            try expect(longAction.usesIconOnly(in: narrow, at: 0), "Crowded wedge should hide an overflowing label")
            try expect(!longAction.usesIconOnly(in: wide, at: 0), "Roomy wedge should retain its label")
            let mixed = RadialWheelView(items: [RadialItem(fileAction: .copyPath), longAction],
                                        highlighted: nil, title: "FILE ACTIONS", emptyMessage: "", emptyDetail: "",
                                        geometry: narrow)
            try expect(mixed.iconOnly, "All wedges should switch to icons if one label does not fit")
        }

        runner.finish()
    }
}
