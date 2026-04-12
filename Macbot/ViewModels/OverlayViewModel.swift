import Foundation
import AppKit
import ScreenCaptureKit

// MARK: - Annotation Model

enum AnnotationType {
    case highlight
    case arrow
    case label
}

struct OverlayAnnotation: Identifiable {
    let id = UUID()
    let rect: CGRect
    let label: String
    let color: AnnotationColor
    let type: AnnotationType

    enum AnnotationColor {
        case green, amber, red

        var nsColor: NSColor {
            switch self {
            case .green: .systemGreen
            case .amber: .systemOrange
            case .red:   .systemRed
            }
        }
    }
}

// MARK: - Overlay State

enum OverlayState {
    case hidden
    case active
    case processing
}

// MARK: - ViewModel

@Observable
@MainActor
final class OverlayViewModel {
    var screenCapture: NSImage?
    var annotations: [OverlayAnnotation] = []
    var selectedRegion: CGRect?
    var response: String?
    var isProcessing = false
    var overlayState: OverlayState = .hidden
    var inputText = ""
    var permissionDenied = false
    var permissionMessage = ""

    // Drag tracking
    var dragStart: CGPoint?
    var dragCurrent: CGPoint?

    var onDismiss: (() -> Void)?

    private let orchestrator: Orchestrator
    private let userId = "overlay"

    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    /// The live drag rectangle while the user is dragging.
    var dragRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    // MARK: - Screen Capture

    /// Check if screen recording is permitted WITHOUT triggering a prompt.
    static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission. Opens the system dialog.
    /// Returns true if already granted, false if the user needs to
    /// grant it (they'll need to restart the app after).
    static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func captureScreen() {
        overlayState = .active
        annotations.removeAll()
        selectedRegion = nil
        response = nil
        inputText = ""
        permissionDenied = false

        // Pre-check permission before attempting capture.
        // CGPreflightScreenCaptureAccess returns the current state
        // without triggering a prompt.
        if !Self.hasScreenCapturePermission {
            // Request permission — this opens the system dialog on first call,
            // and is a no-op on subsequent calls. The user MUST restart the
            // app after granting for it to take effect (macOS requirement).
            let granted = Self.requestScreenCapturePermission()
            if !granted {
                permissionDenied = true
                permissionMessage = "Screen Recording permission required.\n\n"
                    + "1. Open System Settings > Privacy & Security > Screen & System Audio Recording\n"
                    + "2. Enable macbot in the list\n"
                    + "3. Restart macbot for the change to take effect\n\n"
                    + "macOS requires an app restart after granting this permission."
                return
            }
        }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else { return }

                // Exclude our own overlay window so we capture what's
                // underneath, not a screenshot of the dimmed overlay.
                let overlayWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let filter = SCContentFilter(
                    display: display, excludingWindows: overlayWindows
                )
                let config = SCStreamConfiguration()
                config.width = display.width * 2
                config.height = display.height * 2
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                self.screenCapture = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: display.width, height: display.height)
                )
            } catch {
                Log.app.error("Overlay screen capture failed: \(error.localizedDescription)")
                self.permissionDenied = true
                self.permissionMessage = "Screen capture failed: \(error.localizedDescription)\n\n"
                    + "If you just granted permission, restart macbot — "
                    + "macOS requires a restart for Screen Recording to take effect."
            }
        }
    }

    // MARK: - Region Analysis

    func analyzeRegion(_ rect: CGRect) {
        guard let capture = screenCapture else { return }
        selectedRegion = rect
        isProcessing = true
        overlayState = .processing
        response = nil

        Task {
            // Crop the selected region from the capture
            let imageSize = capture.size
            // The rect is in view coordinates; scale to image coordinates
            let scaleX = imageSize.width / (NSScreen.main?.frame.width ?? imageSize.width)
            let scaleY = imageSize.height / (NSScreen.main?.frame.height ?? imageSize.height)
            let scaledRect = CGRect(
                x: rect.origin.x * scaleX,
                y: rect.origin.y * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )

            var imageData: Data?
            if let cgImage = capture.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                if let cropped = cgImage.cropping(to: scaledRect) {
                    let bitmapRep = NSBitmapImageRep(cgImage: cropped)
                    imageData = bitmapRep.representation(using: .png, properties: [:])
                }
            }

            let prompt = inputText.isEmpty
                ? "Describe what you see in this screen region. Identify UI elements, text, and anything notable."
                : inputText

            do {
                let result: String
                if let data = imageData {
                    result = try await orchestrator.handleMessage(
                        userId: userId, message: prompt, images: [data]
                    )
                } else {
                    result = try await orchestrator.handleMessage(
                        userId: userId, message: prompt
                    )
                }
                self.response = result
            } catch {
                self.response = "Error: \(error.localizedDescription)"
            }

            self.isProcessing = false
            self.overlayState = .active
        }
    }

    /// Analyze the full screen with a text query.
    func analyzeFullScreen() {
        guard !inputText.isEmpty else { return }
        guard let capture = screenCapture else { return }
        isProcessing = true
        overlayState = .processing
        response = nil

        Task {
            var imageData: Data?
            if let cgImage = capture.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                imageData = bitmapRep.representation(using: .png, properties: [:])
            }

            do {
                let result: String
                if let data = imageData {
                    result = try await orchestrator.handleMessage(
                        userId: userId, message: inputText, images: [data]
                    )
                } else {
                    result = try await orchestrator.handleMessage(
                        userId: userId, message: inputText
                    )
                }
                self.response = result
            } catch {
                self.response = "Error: \(error.localizedDescription)"
            }

            self.isProcessing = false
            self.overlayState = .active
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        overlayState = .hidden
        screenCapture = nil
        annotations.removeAll()
        selectedRegion = nil
        response = nil
        isProcessing = false
        inputText = ""
        dragStart = nil
        dragCurrent = nil
        permissionDenied = false
    }
}
