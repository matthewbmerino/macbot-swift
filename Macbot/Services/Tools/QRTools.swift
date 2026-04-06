import Foundation

enum QRTools {

    static let generateQRSpec = ToolSpec(
        name: "generate_qr",
        description: "Generate a QR code image from text or a URL. Returns an inline image. Use when the user asks for a QR code.",
        properties: [
            "content": .init(type: "string", description: "Text or URL to encode in the QR code"),
            "label": .init(type: "string", description: "Optional label to display below the QR code"),
        ],
        required: ["content"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(generateQRSpec) { args in
            await generateQR(
                content: args["content"] as? String ?? "",
                label: args["label"] as? String
            )
        }
    }

    // MARK: - Generate QR Code

    static func generateQR(content: String, label: String?) async -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty content" }

        let chartId = UUID().uuidString.prefix(8)
        let qrPath = "/tmp/macbot_qr_\(chartId).png"
        let escapedContent = trimmed.replacingOccurrences(of: "'", with: "\\'")
        let escapedLabel = (label ?? "").replacingOccurrences(of: "'", with: "\\'")

        let script = """
        import qrcode
        from PIL import Image, ImageDraw, ImageFont
        import sys

        BG = '#0d1117'
        FG = '#c9d1d9'

        # Generate QR code
        qr = qrcode.QRCode(version=None, error_correction=qrcode.constants.ERROR_CORRECT_H, box_size=12, border=4)
        qr.add_data('\(escapedContent)')
        qr.make(fit=True)

        # Create QR image with dark theme
        qr_img = qr.make_image(fill_color=FG, back_color=BG).convert('RGB')
        qr_w, qr_h = qr_img.size

        # Add label if provided
        label = '\(escapedLabel)'
        padding = 40

        if label:
            # Create canvas with room for label
            canvas_h = qr_h + padding + 30
            canvas = Image.new('RGB', (qr_w, canvas_h), BG)
            canvas.paste(qr_img, (0, 0))

            draw = ImageDraw.Draw(canvas)
            try:
                font = ImageFont.truetype('/System/Library/Fonts/SFNSMono.ttf', 16)
            except:
                try:
                    font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 16)
                except:
                    font = ImageFont.load_default()

            bbox = draw.textbbox((0, 0), label, font=font)
            text_w = bbox[2] - bbox[0]
            x = (qr_w - text_w) // 2
            draw.text((x, qr_h + 10), label, fill=FG, font=font)
            canvas.save('\(qrPath)', dpi=(150, 150))
        else:
            qr_img.save('\(qrPath)', dpi=(150, 150))

        print('OK')
        """

        let result = await ExecutorTools.runPython(code: script)

        if FileManager.default.fileExists(atPath: qrPath) {
            let desc = label ?? String(trimmed.prefix(50))
            return "QR code for: \(desc)\n[IMAGE:\(qrPath)]"
        }

        return "QR generation failed: \(result)"
    }
}
