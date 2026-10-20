on run argv
    tell application id "com.googlecode.iterm2"
        activate
        create window with default profile command (item 1 of argv)
    end tell
end run
