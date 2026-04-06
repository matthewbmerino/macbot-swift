import Foundation

enum ScreenTools {

    static let screenOCRSpec = ToolSpec(
        name: "screen_ocr",
        description: "Capture the screen (or a specific app window) and extract all visible text using OCR. Returns extracted text and the screenshot image. Use when the user asks 'what does my screen say', 'read the error on screen', or 'what's on my screen'.",
        properties: [
            "app": .init(type: "string", description: "Optional app name to capture only that window (e.g., 'Terminal', 'Safari'). Omit for full screen."),
        ]
    )

    static let screenRegionOCRSpec = ToolSpec(
        name: "screen_region_ocr",
        description: "Let the user select a screen region interactively, then extract text from it via OCR. Use when the user wants to read a specific part of their screen.",
        properties: [:]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(screenOCRSpec) { args in
            await screenOCR(app: args["app"] as? String)
        }
        await registry.register(screenRegionOCRSpec) { _ in
            await screenRegionOCR()
        }
    }

    // MARK: - Full Screen / App Window OCR

    static func screenOCR(app: String?) async -> String {
        let screenshotPath = "/tmp/macbot_ocr_\(UUID().uuidString.prefix(8)).png"

        // Capture screenshot
        if let appName = app?.trimmingCharacters(in: .whitespaces), !appName.isEmpty {
            // Get window ID for the app and capture just that window
            let script = """
            tell application "System Events"
                set frontApp to first application process whose name is "\(appName)"
                set appWindow to first window of frontApp
                set {x, y} to position of appWindow
                set {w, h} to size of appWindow
                return (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)
            end tell
            """
            let bounds = await runAppleScript(script)
            if !bounds.isEmpty && bounds.contains(",") {
                _ = await shell("screencapture -x -R\(bounds) '\(screenshotPath)'")
            } else {
                // Fallback to full screen
                _ = await shell("screencapture -x '\(screenshotPath)'")
            }
        } else {
            _ = await shell("screencapture -x '\(screenshotPath)'")
        }

        guard FileManager.default.fileExists(atPath: screenshotPath) else {
            return "Error: screenshot failed — grant Screen Recording permission in System Settings > Privacy & Security"
        }

        // Run OCR via macOS Vision framework (Python + PyObjC)
        let ocrText = await runVisionOCR(imagePath: screenshotPath)

        var result = ""
        if !ocrText.isEmpty {
            result += "Extracted text:\n\(ocrText)\n\n"
        } else {
            result += "OCR could not extract text (image may not contain readable text, or PyObjC is not installed).\n\n"
        }
        result += "[IMAGE:\(screenshotPath)]"

        return result
    }

    // MARK: - Interactive Region OCR

    static func screenRegionOCR() async -> String {
        let screenshotPath = "/tmp/macbot_region_\(UUID().uuidString.prefix(8)).png"

        // -i = interactive selection, -s = selection mode
        _ = await shell("screencapture -i -s '\(screenshotPath)'")

        guard FileManager.default.fileExists(atPath: screenshotPath) else {
            return "Error: no region selected or screenshot failed"
        }

        let ocrText = await runVisionOCR(imagePath: screenshotPath)

        var result = ""
        if !ocrText.isEmpty {
            result += "Extracted text:\n\(ocrText)\n\n"
        }
        result += "[IMAGE:\(screenshotPath)]"

        return result
    }

    // MARK: - Vision OCR via Python

    private static func runVisionOCR(imagePath: String) async -> String {
        // Use macOS Vision framework through Python/PyObjC
        // Falls back to pytesseract if PyObjC unavailable
        let code = """
        import sys

        text = ""

        # Try macOS Vision framework (PyObjC)
        try:
            import Quartz
            from Foundation import NSURL
            import Vision

            image_url = NSURL.fileURLWithPath_('\(imagePath)')
            image_source = Quartz.CGImageSourceCreateWithURL(image_url, None)
            if image_source:
                image = Quartz.CGImageSourceCreateImageAtIndex(image_source, 0, None)
                if image:
                    request = Vision.VNRecognizeTextRequest.alloc().init()
                    request.setRecognitionLevel_(1)  # Accurate
                    request.setUsesLanguageCorrection_(True)
                    handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(image, None)
                    success, error = handler.performRequests_error_([request], None)
                    if success and request.results():
                        lines = []
                        for observation in request.results():
                            candidate = observation.topCandidates_(1)
                            if candidate:
                                lines.append(candidate[0].string())
                        text = '\\n'.join(lines)
        except ImportError:
            pass
        except Exception as e:
            print(f"Vision OCR error: {e}", file=sys.stderr)

        # Fallback: pytesseract
        if not text:
            try:
                from PIL import Image
                import pytesseract
                img = Image.open('\(imagePath)')
                text = pytesseract.image_to_string(img)
            except ImportError:
                pass
            except Exception as e:
                print(f"Tesseract error: {e}", file=sys.stderr)

        print(text.strip() if text else "")
        """

        let result = await ExecutorTools.runPython(code: code)
        // Filter out STDERR lines
        let lines = result.components(separatedBy: "\n")
        let textLines = lines.filter { !$0.hasPrefix("STDERR:") && !$0.hasPrefix("Error:") }
        return textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func shell(_ command: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate() }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func runAppleScript(_ script: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}
