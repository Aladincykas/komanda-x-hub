-- config.lua -- central settings for the Komanda X media hub.
-- Edit the values below to match your world; nothing else in hub/ should
-- need touching for a basic setup.

return {
    TITLE = "Komanda X",

    -- Peripheral identifier for the monitor. If it's directly attached to
    -- the Computer (no wired modem in between), use the side it's touching:
    -- "back" | "front" | "left" | "right" | "top" | "bottom" -- both work
    -- with peripheral.wrap the same way. Use the network name (e.g.
    -- "monitor_295", as shown by `peripheral.getNames()`) if it's reached
    -- through a modem instead.
    MONITOR_NAME = "back",
    -- Confirmed in-game via a diagnostic print: this monitor reports
    -- 143x81 characters at scale 0.5 -- CC:Tweaked's character grid is
    -- roughly inversely proportional to scale, so scale 1.0 should land
    -- close to 71x40 (much bigger, more legible text; fewer, larger touch
    -- targets). Bump this further (1.5, 2...) if it's still too small, or
    -- back toward 0.5 if you want more content density instead. Re-run
    -- hub/basalttest.lua after changing this to see the new mon size.
    MONITOR_TEXT_SCALE = 1.0,

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
    VIDEO_MENU_IDLE_TIMEOUT_SEC = 300,   -- video list -> main menu
    MUSIC_MENU_IDLE_TIMEOUT_SEC = 300,   -- music library OR now-playing (idle mid-song forces all the way to main menu) -> main menu

    DEFAULT_VOLUME = 1.0,
    MAX_VOLUME = 3.0, -- CC:Tweaked speaker.playAudio volume ceiling

    -- CC:Tweaked hard-caps concurrent speaker playback at 8, network-wide --
    -- a real engine limitation (see hub.lua's note where this is read), not
    -- something this hub can work around. Extra speakers beyond this many
    -- are simply ignored rather than used unreliably.
    MAX_SPEAKERS = 8,
}
