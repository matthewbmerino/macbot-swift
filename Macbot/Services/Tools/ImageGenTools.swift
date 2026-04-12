import Foundation
import Hub
import MLX
import StableDiffusion

enum ImageGenTools {

    static let generateImageSpec = ToolSpec(
        name: "generate_image",
        description: "Generate an image from a text description using on-device AI (SDXL-Turbo). Runs entirely on this Mac via Metal GPU — no cloud, no internet needed after first model download. Returns an inline image.",
        properties: [
            "prompt": .init(type: "string", description: "Detailed description of the image to generate (e.g., 'a cat sitting on a keyboard in a cozy office, digital art')"),
            "negative_prompt": .init(type: "string", description: "Optional: what to avoid in the image (e.g., 'blurry, low quality')"),
            "size": .init(type: "string", description: "Image size: small (256x256), medium (512x512, default), large (768x768)"),
            "seed": .init(type: "string", description: "Optional random seed for reproducible results"),
        ],
        required: ["prompt"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(generateImageSpec) { args in
            await generateImage(
                prompt: args["prompt"] as? String ?? "",
                negativePrompt: args["negative_prompt"] as? String,
                size: args["size"] as? String ?? "medium",
                seed: args["seed"] as? String
            )
        }
    }

    // MARK: - Generate Image

    static func generateImage(
        prompt: String,
        negativePrompt: String?,
        size: String,
        seed: String?
    ) async -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty prompt" }

        let outputPath = "/tmp/macbot_imagegen_\(UUID().uuidString.prefix(8)).png"
        let outputURL = URL(fileURLWithPath: outputPath)

        // Determine latent size (image size = latent * 8)
        let latentSize: [Int]
        switch size.lowercased().trimmingCharacters(in: .whitespaces) {
        case "small", "256":
            latentSize = [32, 32]   // 256x256
        case "large", "768":
            latentSize = [96, 96]   // 768x768
        default:
            latentSize = [64, 64]   // 512x512
        }

        // Parse seed
        let seedValue: UInt64
        if let seedStr = seed, let parsed = UInt64(seedStr.trimmingCharacters(in: .whitespaces)) {
            seedValue = parsed
        } else {
            seedValue = UInt64(Date.timeIntervalSinceReferenceDate * 1000)
        }

        // Determine quality based on available memory
        let quantize = shouldQuantize()

        do {
            // Ensure model is downloaded
            let configuration = StableDiffusionConfiguration.presetSDXLTurbo
            try await ensureDownloaded(configuration: configuration)

            // Create generator with conserveMemory to free VRAM after generation
            let loadConfig = LoadConfiguration(float16: true, quantize: quantize)
            let container = try ModelContainer<TextToImageGenerator>.createTextToImageGenerator(
                configuration: configuration, loadConfiguration: loadConfig
            )
            await container.setConserveMemory(true)

            // Build parameters — SDXL-Turbo uses cfg=0, steps=2.
            // Build as a `var` then shadow into a `let` so the concurrent
            // `performTwoStage` closure captures an immutable copy (avoids
            // the Swift 6 captured-var warning).
            var builtParameters = configuration.defaultParameters()
            builtParameters.prompt = trimmed
            builtParameters.negativePrompt = negativePrompt ?? ""
            builtParameters.latentSize = latentSize
            builtParameters.seed = seedValue
            let parameters = builtParameters

            Log.tools.info("Generating image: \"\(trimmed)\" [\(latentSize[0]*8)x\(latentSize[1]*8)] seed=\(seedValue) quantize=\(quantize)")

            // Generate: two-stage to conserve memory
            // Stage 1: generate latents (uses UNet + text encoder)
            // Stage 2: decode to image (uses VAE decoder, model discarded after)
            let image = try await container.performTwoStage { generator in
                // Generate all latent steps
                var xt: MLXArray?
                for latent in generator.generateLatents(parameters: parameters) {
                    eval(latent)
                    xt = latent
                }
                return (xt!, generator.detachedDecoder())
            } second: { (pair: (MLXArray, ImageDecoder)) in
                let (xt, decoder) = pair
                let decoded = decoder(xt)
                eval(decoded)
                return Image(decoded)
            }

            // Save to file
            try image.save(url: outputURL)

            Log.tools.info("Image saved to \(outputPath)")
            return "Generated: \(trimmed)\n[IMAGE:\(outputPath)]"

        } catch {
            Log.tools.error("Image generation failed: \(error)")
            return "Error generating image: \(error.localizedDescription)"
        }
    }

    // MARK: - Model Download

    private static func ensureDownloaded(configuration: StableDiffusionConfiguration) async throws {
        // Check if model files exist locally
        let hub = HubApi()
        let repo = Hub.Repo(id: configuration.id)
        let localDir = hub.localRepoLocation(repo)

        // Check for the UNet weights as a proxy for "model is downloaded"
        let unetPath = localDir.appending(path: "unet/diffusion_pytorch_model.safetensors")
        if FileManager.default.fileExists(atPath: unetPath.path) {
            return // Already downloaded
        }

        Log.tools.info("Downloading SDXL-Turbo model (first time only, ~6.5GB)...")
        try await configuration.download(hub: hub) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct % 10 == 0 {
                Log.tools.info("Download progress: \(pct)%")
            }
        }
        Log.tools.info("Model download complete")
    }

    // MARK: - Memory Management

    private static func shouldQuantize() -> Bool {
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        // On 18GB Mac: ~13GB available. Ollama uses 4-8GB. Quantized SD uses ~2GB vs 3.4GB float16.
        // Use quantized if total RAM <= 16GB to be safe.
        return totalGB <= 16
    }
}
