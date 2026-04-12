import Foundation

// MARK: - Skill Injection & Learned Tool Routing

extension Orchestrator {

    /// Inject learned skills + apply learned tool routing in a single pass
    /// that embeds the message exactly once and runs both consumers
    /// concurrently. Previously these were two sequential helpers, each
    /// independently embedding the same query — two Ollama round-trips per
    /// turn for no reason. This collapses that to one round-trip and runs
    /// the two k-NN steps in parallel.
    @discardableResult
    func injectSkillsAndLearnedRouting(agent: BaseAgent, message: String) async -> LearnedPrediction? {
        // 1. Embed the user message once.
        let queryVec: [Float]
        do {
            let vecs = try await client.embed(model: modelConfig.embedding, text: [message])
            queryVec = vecs.first ?? []
        } catch {
            queryVec = []
        }

        // Empty embedding → both downstream consumers degrade gracefully.
        if queryVec.isEmpty {
            agent.learnedToolHints = []
            return nil
        }

        // 2. Run skill retrieval and learned routing concurrently. Skill
        //    retrieval scans the SkillStore in-memory; learned routing
        //    scans TraceStore's vector index. Neither touches the network
        //    after the embed above, so they're cheap to parallelize.
        async let skillsTask = SkillStore.shared.retrieve(forQueryEmbedding: queryVec, topK: 5)
        async let predictionTask = LearnedRouter.predict(
            forQueryEmbedding: queryVec,
            topK: 8,
            minSimilarity: 0.55
        )
        let (skills, prediction) = await (skillsTask, predictionTask)

        // 3. Apply the results.
        let block = SkillStore.formatForPrompt(skills)
        if !block.isEmpty {
            agent.history.append(["role": "system", "content": block])
        }
        agent.learnedToolHints = prediction?.tools ?? []
        if let prediction, !prediction.tools.isEmpty {
            ActivityLog.shared.log(
                .routing,
                "Learned hints: \(prediction.tools.joined(separator: ",")) (\(prediction.neighborCount) neighbors, sim=\(String(format: "%.2f", prediction.topSimilarity)))"
            )
        }
        return prediction
    }

    // Legacy entry points kept for any external callers; they delegate to the
    // combined helper above so there's no duplicated embedding cost.
    func injectLearnedSkills(agent: BaseAgent, message: String) async {
        _ = await injectSkillsAndLearnedRouting(agent: agent, message: message)
    }

    func applyLearnedRouting(agent: BaseAgent, message: String) async -> LearnedPrediction? {
        await injectSkillsAndLearnedRouting(agent: agent, message: message)
    }
}
