import Foundation

enum MediaTools {

    static let nowPlayingSpec = ToolSpec(
        name: "now_playing",
        description: "Get the currently playing song/track info from Music.app or Spotify.",
        properties: [:]
    )

    static let mediaControlSpec = ToolSpec(
        name: "media_control",
        description: "Control music playback: play, pause, next, previous, or toggle play/pause. Works with Music.app and Spotify.",
        properties: [
            "action": .init(type: "string", description: "One of: play, pause, toggle, next, previous"),
        ],
        required: ["action"]
    )

    static let setVolumeSpec = ToolSpec(
        name: "set_volume",
        description: "Set the system audio volume (0-100).",
        properties: ["level": .init(type: "string", description: "Volume level 0-100")],
        required: ["level"]
    )

    static let searchPlaySpec = ToolSpec(
        name: "search_play",
        description: "Search for and play a song, artist, album, or playlist in Music.app or Spotify.",
        properties: [
            "query": .init(type: "string", description: "Song, artist, or album to search for"),
            "app": .init(type: "string", description: "Music or Spotify (default: auto-detect)"),
        ],
        required: ["query"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(nowPlayingSpec) { _ in
            await nowPlaying()
        }
        await registry.register(mediaControlSpec) { args in
            await mediaControl(action: args["action"] as? String ?? "toggle")
        }
        await registry.register(setVolumeSpec) { args in
            setVolume(level: args["level"] as? String ?? "50")
        }
        await registry.register(searchPlaySpec) { args in
            await searchAndPlay(
                query: args["query"] as? String ?? "",
                app: args["app"] as? String
            )
        }
    }

    // MARK: - Now Playing

    static func nowPlaying() async -> String {
        // Try Spotify first (more common for active users)
        let spotify = await runAppleScript("""
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    set al to album of current track
                    set pos to player position as integer
                    set dur to (duration of current track) / 1000 as integer
                    set posMin to pos div 60
                    set posSec to pos mod 60
                    set durMin to dur div 60
                    set durSec to dur mod 60
                    return "Spotify | " & t & " | " & a & " | " & al & " | " & posMin & ":" & text -2 thru -1 of ("0" & posSec) & " / " & durMin & ":" & text -2 thru -1 of ("0" & durSec)
                else
                    return "Spotify | paused"
                end if
            end tell
        end if
        return ""
        """)

        if !spotify.isEmpty && spotify != "" {
            if spotify.contains("paused") {
                return "Spotify: paused"
            }
            let parts = spotify.components(separatedBy: " | ")
            if parts.count >= 5 {
                return """
                Now Playing (Spotify)
                  Track: \(parts[1])
                  Artist: \(parts[2])
                  Album: \(parts[3])
                  Position: \(parts[4])
                """
            }
        }

        // Try Music.app
        let music = await runAppleScript("""
        if application "Music" is running then
            tell application "Music"
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    set al to album of current track
                    set pos to player position as integer
                    set dur to duration of current track as integer
                    set posMin to pos div 60
                    set posSec to pos mod 60
                    set durMin to dur div 60
                    set durSec to dur mod 60
                    return "Music | " & t & " | " & a & " | " & al & " | " & posMin & ":" & text -2 thru -1 of ("0" & posSec) & " / " & durMin & ":" & text -2 thru -1 of ("0" & durSec)
                else
                    return "Music | paused"
                end if
            end tell
        end if
        return ""
        """)

        if !music.isEmpty && music != "" {
            if music.contains("paused") {
                return "Music.app: paused"
            }
            let parts = music.components(separatedBy: " | ")
            if parts.count >= 5 {
                return """
                Now Playing (Music)
                  Track: \(parts[1])
                  Artist: \(parts[2])
                  Album: \(parts[3])
                  Position: \(parts[4])
                """
            }
        }

        return "Nothing playing. Music.app and Spotify are either not running or paused."
    }

    // MARK: - Media Control

    static func mediaControl(action: String) async -> String {
        let act = action.lowercased().trimmingCharacters(in: .whitespaces)

        // Determine which app is active
        let isSpotify = await runAppleScript("if application \"Spotify\" is running then return \"yes\"")

        let appName = isSpotify == "yes" ? "Spotify" : "Music"

        let command: String
        switch act {
        case "play":
            command = "play"
        case "pause":
            command = "pause"
        case "toggle":
            command = "playpause"
        case "next", "skip":
            command = "next track"
        case "previous", "prev", "back":
            command = "previous track"
        default:
            return "Error: unknown action '\(act)'. Use: play, pause, toggle, next, previous"
        }

        // appName comes from either a validated branch above or user input;
        // escape defensively in case a future refactor widens the call site.
        // `command` is from a closed switch so it's already safe.
        let safeApp = InjectionSafety.escapeAppleScriptString(appName)
        _ = await runAppleScript("tell application \"\(safeApp)\" to \(command)")
        return "\(appName): \(act)"
    }

    // MARK: - Volume

    static func setVolume(level: String) -> String {
        let vol = Int(level) ?? 50
        let clamped = max(0, min(100, vol))
        let script = NSAppleScript(source: "set volume output volume \(clamped)")
        script?.executeAndReturnError(nil)
        return "Volume set to \(clamped)%"
    }

    // MARK: - Search and Play

    static func searchAndPlay(query: String, app: String?) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty search query" }

        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")

        // Determine target app
        let targetApp: String
        if let specified = app?.lowercased(), specified.contains("spotify") {
            targetApp = "Spotify"
        } else if let specified = app?.lowercased(), specified.contains("music") {
            targetApp = "Music"
        } else {
            let isSpotify = await runAppleScript("if application \"Spotify\" is running then return \"yes\"")
            targetApp = isSpotify == "yes" ? "Spotify" : "Music"
        }

        if targetApp == "Spotify" {
            // Spotify doesn't have great AppleScript search — use the URI scheme
            let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            _ = await runAppleScript("open location \"spotify:search:\(encodedQuery)\"")
            return "Opened Spotify search for '\(trimmed)'. Select a result to play."
        } else {
            // Music.app — search library
            let result = await runAppleScript("""
            tell application "Music"
                activate
                set results to search playlist "Library" for "\(escaped)"
                if (count of results) > 0 then
                    play item 1 of results
                    set t to name of current track
                    set a to artist of current track
                    return "Playing: " & t & " by " & a
                else
                    return "No results found for '\(escaped)'"
                end if
            end tell
            """)
            return result
        }
    }

    // MARK: - Helper

    private static func runAppleScript(_ script: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { process.terminate() }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}
