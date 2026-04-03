import Foundation

/// Speculative decoding implementation for MLX.
///
/// Uses a small "draft" model to generate candidate token sequences quickly,
/// then verifies them against the larger "target" model in a single forward pass.
/// Accepted tokens skip individual autoregressive steps, yielding 2-3x speedup.
///
/// Algorithm (Leviathan et al., 2023):
/// 1. Draft model generates K candidate tokens autoregressively
/// 2. Target model scores all K+1 positions in one forward pass
/// 3. For each position i (left to right):
///    - If target agrees with draft: accept token
///    - If target disagrees: sample from adjusted distribution, reject rest
/// 4. Always sample one bonus token from target at the accepted frontier
///
/// On Apple Silicon unified memory, both models share the same memory pool,
/// so the draft model's weights don't compete with the target's KV cache.
final class SpeculativeDecoder {
    struct Config {
        var draftTokens: Int = 5          // K: number of speculative tokens per step
        var maxDraftTokens: Int = 8       // Upper bound for adaptive K
        var minDraftTokens: Int = 2       // Lower bound for adaptive K
        var adaptiveK: Bool = true        // Dynamically adjust K based on acceptance rate
        var acceptanceThreshold: Float = 0.1  // Min probability ratio for acceptance
    }

    struct Metrics {
        var totalDraftTokens: Int = 0
        var acceptedTokens: Int = 0
        var totalSteps: Int = 0
        var totalTargetForwardPasses: Int = 0

        var acceptanceRate: Double {
            totalDraftTokens > 0 ? Double(acceptedTokens) / Double(totalDraftTokens) : 0
        }

        var speedupEstimate: Double {
            // Theoretical speedup = (accepted + 1) / 1 per target forward pass
            totalTargetForwardPasses > 0
                ? Double(acceptedTokens + totalTargetForwardPasses) / Double(totalTargetForwardPasses)
                : 1.0
        }

        var summary: String {
            "acceptance=\(String(format: "%.1f%%", acceptanceRate * 100)) " +
            "speedup=\(String(format: "%.1fx", speedupEstimate)) " +
            "steps=\(totalSteps)"
        }
    }

    private let config: Config
    private(set) var metrics = Metrics()
    private var currentK: Int

    init(config: Config = Config()) {
        self.config = config
        self.currentK = config.draftTokens
    }

    /// Reset metrics for a new generation session.
    func resetMetrics() {
        metrics = Metrics()
        currentK = config.draftTokens
    }

    /// Perform one step of speculative decoding.
    ///
    /// - Parameters:
    ///   - draftLogits: Logits from draft model for K candidate positions [K x vocab]
    ///   - draftTokens: Token IDs selected by draft model [K]
    ///   - targetLogits: Logits from target model for K+1 positions [(K+1) x vocab]
    ///   - temperature: Sampling temperature
    ///
    /// - Returns: Accepted token IDs (1 to K+1 tokens)
    func verifyStep(
        draftLogits: [[Float]],
        draftTokens: [Int],
        targetLogits: [[Float]],
        temperature: Float
    ) -> [Int] {
        metrics.totalSteps += 1
        metrics.totalTargetForwardPasses += 1
        metrics.totalDraftTokens += draftTokens.count

        guard !draftTokens.isEmpty,
              draftLogits.count == draftTokens.count,
              targetLogits.count == draftTokens.count + 1
        else {
            // Fallback: just sample from target's first position
            if let firstTargetLogits = targetLogits.first {
                return [sampleFromLogits(firstTargetLogits, temperature: temperature)]
            }
            return []
        }

        var accepted: [Int] = []
        let vocabSize = targetLogits[0].count

        for i in 0..<draftTokens.count {
            let draftToken = draftTokens[i]
            guard draftToken >= 0, draftToken < vocabSize else { break }

            // Compute acceptance probability
            let draftProbs = softmax(draftLogits[i], temperature: temperature)
            let targetProbs = softmax(targetLogits[i], temperature: temperature)

            let pDraft = draftProbs[draftToken]
            let pTarget = targetProbs[draftToken]

            // Accept if target probability >= draft probability
            // (standard speculative sampling criterion)
            if pDraft > 0 {
                let acceptProb = min(1.0, pTarget / pDraft)
                let r = Float.random(in: 0..<1)

                if r < acceptProb {
                    accepted.append(draftToken)
                    metrics.acceptedTokens += 1
                } else {
                    // Reject: sample from adjusted distribution
                    // p_adjusted(x) = max(0, p_target(x) - p_draft(x)) / Z
                    var adjusted = [Float](repeating: 0, count: vocabSize)
                    var sum: Float = 0
                    for j in 0..<vocabSize {
                        adjusted[j] = max(0, targetProbs[j] - draftProbs[j])
                        sum += adjusted[j]
                    }
                    if sum > 0 {
                        for j in 0..<vocabSize { adjusted[j] /= sum }
                    }
                    accepted.append(sampleFromDistribution(adjusted))
                    break  // Stop accepting after first rejection
                }
            } else {
                // Draft assigned zero probability — sample from target directly
                accepted.append(sampleFromLogits(targetLogits[i], temperature: temperature))
                break
            }
        }

        // If all draft tokens accepted, sample bonus token from target's last position
        if accepted.count == draftTokens.count {
            let bonusLogits = targetLogits[draftTokens.count]
            accepted.append(sampleFromLogits(bonusLogits, temperature: temperature))
        }

        // Adaptive K adjustment
        if config.adaptiveK {
            adaptK(accepted: accepted.count, drafted: draftTokens.count)
        }

        return accepted
    }

    /// Get the current number of draft tokens to generate.
    var draftCount: Int { currentK }

    // MARK: - Adaptive K

    /// Adjust the number of draft tokens based on recent acceptance rates.
    /// High acceptance → increase K (more aggressive speculation)
    /// Low acceptance → decrease K (reduce wasted draft computation)
    private func adaptK(accepted: Int, drafted: Int) {
        let rate = drafted > 0 ? Float(accepted) / Float(drafted) : 0

        if rate > 0.8 && currentK < config.maxDraftTokens {
            currentK += 1
        } else if rate < 0.3 && currentK > config.minDraftTokens {
            currentK -= 1
        }
    }

    // MARK: - Sampling Utilities

    private func softmax(_ logits: [Float], temperature: Float) -> [Float] {
        let temp = max(temperature, 1e-7)
        let scaled = logits.map { $0 / temp }
        let maxVal = scaled.max() ?? 0
        let exps = scaled.map { exp($0 - maxVal) }
        let sum = exps.reduce(0, +)
        return sum > 0 ? exps.map { $0 / sum } : exps
    }

    private func sampleFromLogits(_ logits: [Float], temperature: Float) -> Int {
        let probs = softmax(logits, temperature: temperature)
        return sampleFromDistribution(probs)
    }

    private func sampleFromDistribution(_ probs: [Float]) -> Int {
        let r = Float.random(in: 0..<1)
        var cumulative: Float = 0
        for (i, p) in probs.enumerated() {
            cumulative += p
            if r < cumulative { return i }
        }
        return probs.count - 1
    }
}
