-- config.lua -- central settings for the Komanda X media hub.
-- Edit the values below to match your world; nothing else in hub/ should
-- need touching for a basic setup.

return {
    TITLE = "Komanda X",

    -- Peripheral names, as shown by `peripheral.getNames()` in-game.
    MONITOR_NAME = "monitor_295",
    MONITOR_TEXT_SCALE = 0.5, -- tune until monitor.getSize() reports 71 x 40

    GITHUB_USER = "Aladincykas",

    -- Same merge pattern as the original music.lua: every repo listed here
    -- gets fetched and merged into one browsable library.
    MUSIC_LIBRARIES = {
        { label = "Library 1", repo = "cctwmusics",  branch = "main" },
        { label = "Library 2", repo = "cctwmusics2", branch = "main" },
        { label = "Library 3", repo = "cctwmusics3", branch = "main" },
    },

    -- Video-only repos -- addmedia/cli.js (Video mode) never touches the
    -- music repos above, and this list never touches songs.json.
    VIDEO_LIBRARIES = {
        { label = "Videos 1", repo = "KCTWM0", branch = "main" },
        { label = "Videos 2", repo = "KCTWM1", branch = "main" },
    },

    -- Main menu
    MENU_MUSIC_VOLUME = 0.5,
    MENU_MUSIC_NAME = nil, -- set to a song name from MUSIC_LIBRARIES once you have a track picked

    -- Idle timeouts, in seconds
    VIDEO_MENU_IDLE_TIMEOUT_SEC = 150,   -- video list -> main menu
    MUSIC_MENU_IDLE_TIMEOUT_SEC = 150,   -- music list -> main menu

    DEFAULT_VOLUME = 1.0,
    MAX_VOLUME = 3.0, -- CC:Tweaked speaker.playAudio volume ceiling
}
