# Decisions

One line per decision, with the reason.

- Sources live at the repo root (`build.sh`, `Info.plist`, `Sources/`) instead of a `steady/` subfolder, because the repo itself is the app and the README tells people to run `./build.sh` from the root.
- Added `Engine.swift`, `EpisodeTracker.swift`, `Theme.swift`, `WindowManager.swift` and `Views/SessionSummaryView.swift` beyond the suggested file list, to keep each file focused (frame loop, shared alert timing rules, colours, window handling, session summary).
- The camera delivers 420f YUV frames instead of BGRA: Vision reads YUV directly and motion energy comes straight from the luma plane, which cut CPU from about 40% to about 30% of one core in measurements.
- Full face detection runs on every 3rd frame. In between, the last landmark observation is passed back in as the face, and a landmark confidence below 0.5 forces a fresh detection. This saved about a third of the remaining CPU.
- The video data output asks for 640x480 buffers explicitly (width and height in `videoSettings`), and the device's 640x480 format is selected directly. On this macOS version the VGA preset alone still delivered 1920x1080 frames. With 640x480 the whole pipeline measures about 11% of one core at 15 fps and about 170 MB of memory with the debug window closed.
- Motion energy uses a block average of the luma plane rather than a CIContext render to `.L8`. The CIContext path is still there for non-YUV frames.
- `Info.plist` sets `NSCameraReactionEffectGesturesEnabledDefault` to false, so macOS camera reaction gestures (thumbs up, hearts) don't trigger effects and burn CPU inside Steady.
- Compute device for Vision requests is left at the system default; forcing the Neural Engine or GPU made no measurable difference.
- The activity score is a weighted average of ratios to calm (motion / calm motion, head speed / calm head speed, body movement / calm body movement, and 1 + 4 x hand-near-face fraction), so a calm moment scores about 1 and the 2.5x threshold means "2.5 times calm".
- Calm baselines exist for motion, head speed and upper-body movement (median of the lowest 30% of per-second averages over 10 minutes). Only motion gets an initial value from smile calibration; over-active alerts wait until motion and head have about 30 seconds of data, to avoid alerts right after launch. Body pose is often missing (shoulders out of view), so its part of the score stays neutral (1.0) until it has 30 seconds of data.
- Alert timing for all four types shares one `EpisodeTracker`: the condition must hold for the hold time, alerts are at least one cooldown apart (inside and across episodes), and there is a cap per episode (smile 3, look-away 3, over-active 1, hands 1).
- Smile and look-away episodes are counted in stats when the hold time is reached, even if the alert itself is held back by the cooldown.
- Feedback samples (false alarm, missed one) are added three times to the training set, so a couple of seconds of feedback can move a model trained on about a minute of calibration.
- A false alarm after an over-active or hands-at-face alert is logged and counted, but there is no model to retrain for those, so the log suggests raising the threshold in debug mode.
- Before gaze calibration, look-away detection uses a head-angle rule (yaw above about 0.42 rad or pitch above about 0.38 rad), so study sessions work from the first launch.
- No face for up to 30 s after a face was seen counts as looking away. From 30 to 45 s it counts as neither. After 45 s it is "away from desk": alerts stop and the session timer pauses.
- Logistic regression trains with shuffled mini-batches of 32 (seeded), 800 epochs, learning rate 0.05, L2 0.01 and balanced class weights. Plain full-batch descent converged too slowly in 800 steps.
- Reported calibration accuracy is balanced accuracy (average of per-class accuracy) on the 20% held-out split, so an uneven split can't flatter the number.
- Z-scores are clamped to plus or minus 6 before the x and x squared expansion, so one odd frame can't dominate a prediction.
- `CGEventSource.secondsSinceLastEventType` is used for typing suppression. It only reports seconds since the last input event (no key codes or positions), and macOS does not require Input Monitoring permission for it; Steady never requests that permission. Worth confirming on first run that no prompt appears.
- Haptics: the enumerated MultitouchSupport device ID on the M4 Air is `0x7000000000000e2`, not the hardcoded `0x200000001000000` from the sample; enumeration through `MTDeviceCreateList` and `MTDeviceGetDeviceID` is tried first, the hardcoded ID last. `MTActuatorOpen` and `MTActuatorActuate` both return 0 on this Mac.
- Over-active and hands-at-face alerts play a light tap (waveform 4) only when their haptic toggle is turned on; both are off by default as asked.
- macOS lets several apps use the built-in camera at once, so Steady keeps running during calls by default. A setting "Turn the camera off during calls" is there in case a call app ever has trouble.
- Calibration windows turn the camera on even while monitoring is paused, and alerts stay off while a calibration window is open.
- The clip buffer keeps an even 10 fps from the 15 fps stream (a frame is taken each time the next 100 ms slot is due) and trims by time, so clips are 10 s before plus 4 s after.
- Clip frames are stored as 480x360 YUV 4:2:0 in a pixel buffer pool (about 26 MB for 14 s instead of about 70 MB as BGRA), which keeps the app under the 250 MB memory target.
- Automatic clip clean-up deletes files right away (to free space); deleting from the Clips window moves them to the Trash, as asked.
- The debug window's "mini" layout is the same window shrunk to a small floating panel, so there is one place for the camera preview.
- `os.Logger` with public messages (subsystem `com.arnav.steady`) mirrors the event log, so `log show --predicate 'subsystem == "com.arnav.steady"'` shows detections without opening debug mode.
- `--show debug,settings,clips,stats,smile,gaze` opens windows at launch; it was added to check layouts without clicking through the menu.
- The app icon is drawn by `scripts/make-icon.swift` with plain bezier paths (no SF Symbols, since their license doesn't allow use in app icons) and cached in `build/`.
- The menu shows hotkeys next to items (⌃⌥S, ⌃⌥X, ⌃⌥M, ⌃⌥D) and also uses section headers and SF Symbols, like native menus.
- Settings use a sidebar (`NavigationSplitView`) with grouped forms, one pane per area.
- The repo stays private; making it public is left to the owner.
