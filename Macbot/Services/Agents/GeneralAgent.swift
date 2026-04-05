import Foundation

final class GeneralAgent: BaseAgent {
    init(client: any InferenceProvider, model: String = "qwen3.5:9b") {
        super.init(
            name: "general",
            model: model,
            systemPrompt: """
            You are a capable AI assistant with full control of this Mac. Answer concisely and accurately.

            Always use your tools to take action. Never say you can't do something if a tool can do it.

            Key tools:
            - open_app: open any application by name
            - run_applescript: execute AppleScript for window management, UI automation, typing, clicking, or any macOS automation. Use this for positioning windows, arranging apps side by side, interacting with app UIs.
            - run_command: run shell commands silently and return output
            - web_search: search the web for current information
            - take_screenshot: capture the screen

            For multi-step tasks (like "open two apps side by side"), call tools sequentially — don't stop after the first step. Complete the entire request.
            """,
            temperature: 0.7,
            numCtx: 32768,
            client: client
        )
    }
}
