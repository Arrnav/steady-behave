# Design notes

Short notes on choices that aren't obvious from the code, with the reason for each.

## Build

- Plain `swiftc` and a shell script, no Xcode project. The build is small and leaves no derived data behind.
- Swift 5 language mode, so strict concurrency checking doesn't block the build. Shared state between the main thread and the camera queue goes through a small `Locked<T>` wrapper.
- Signed with the hardened runtime and a camera entitlement. An "Apple Development" certificate keeps the camera permission across rebuilds, because macOS ties it to the code signature.
- The app icon is drawn with bezier paths by `scripts/make-icon.swift` (SF Symbols may not be used in app icons) and cached in `build/`.

## Camera

- The video data output asks for 640x480 buffers explicitly, and the device's 640x480 format is selected directly. On recent macOS the VGA session preset alone can still deliver 1920x1080 frames.
- 640x480 is the built-in camera's smallest mode and 15 fps its lowest rate. Asking for smaller frames makes macOS scale every frame, which measured costlier than processing the full frame, so the quality setting changes how many frames are analysed instead: High 15 fps, Balanced 10 fps, Battery Saver 5 fps with pose checks on every 4th analysed frame.
- The capture pipeline itself costs about 7 to 8% of one core while the camera is on, whatever the app does with the frames. Analysis comes on top of that, so the biggest savings are a lower rate and the idle mode: after 10 seconds with no face in view, only face detection runs, twice a second.
- Battery Saver is used automatically on battery power (can be turned off) and in Low Power Mode. The power source is checked every 10 seconds.
- Hand pose runs only when hands-at-face is on (or the debug preview is open), and body pose only when over-active detection uses it.
- Frames are 420f YUV. Vision reads YUV directly, and motion energy comes straight from the luma plane, which uses much less CPU than converting every frame to BGRA.
- Frames stay unmirrored, so clips show what other people see. Only the debug preview is mirrored, with a toggle.
- `NSCameraReactionEffectGesturesEnabledDefault` is off, so macOS reaction effects (thumbs up and so on) don't run inside the app.
- macOS lets several apps use the camera at once. Steady keeps watching during calls by default, and Settings has an option to turn the camera off while a call app is in front.

## Vision pipeline

- Full face detection runs on every 3rd frame. In between, the last landmark observation is passed back in as the face, and a landmark confidence below 0.5 forces a fresh detection. This saves about a third of the CPU.
- Hand pose and body pose each run on every 3rd frame, on different frames.
- Memory settles near 200 MB. When CPU use stays above 15%, the frame rate is capped at 10 fps with hand pose every 4th frame. The first 15 seconds are not measured, because loading the Vision models makes them look busier than normal.
- Smoothing of the smile and gaze scores is based on elapsed time (alpha 0.3 per 1/15 s), so alerts react at the same speed at every quality.
- The compute device is left at the system default. Forcing the Neural Engine or GPU made no measurable difference.

## Personal models

- Logistic regression on standardized features expanded to `[x, x²]`, trained with shuffled mini-batches of 32 (seeded), 800 epochs, learning rate 0.05, L2 0.01 and balanced class weights. Z-scores are clamped to ±6 so one odd frame can't dominate.
- Reported accuracy is balanced accuracy on a 20% held-out split, so an uneven split can't flatter the number. The final model is trained on all samples.
- Up to 3000 samples per class are kept for retraining, oldest dropped first. Feedback samples (false alarm, missed one) are added three times, so a couple of seconds of feedback can move a model trained on about a minute of calibration.
- Before gaze calibration, looking away is detected from head angle alone (yaw above about 0.42 rad or pitch above about 0.38 rad).

## Alerts

- All four alert types share one `EpisodeTracker`. The condition must hold for the hold time, alerts are at least one cooldown apart (inside and across episodes), and each episode has a cap (smile 3, look-away 3, over-active 1, hands 1).
- Episodes are counted in stats when the hold time is reached, even if the alert itself is held back by the cooldown.
- Which detections run on a frame is decided in one place, `DetectionGates`, from the settings, the pause state and the focus context. A detection that is switched off gives no alerts, stats or clips. With hands-at-face off, hands near the face also stop raising the activity score.
- No face for up to 30 s after a face was seen counts as looking away. From 30 to 45 s it counts as neither. After 45 s it is "away from desk": alerts stop and the session timer pauses.
- Keyboard and trackpad use are read with `CGEventSource.secondsSinceLastEventType`, which reports only the time since the last event and needs no Input Monitoring permission. Keyboard and mouse can be watched separately, and each detection can be set to pause during input or keep running. By default only looking away pauses; the others keep catching habits while typing. During input, look-away keeps running but counts the time as on screen.
- The edge glow uses an even-odd shape to cut out the notch. A blend-mode mask rendered correctly offscreen but did not composite in a live window.
- Alert colors can be changed per type. Resolved colors are cached and refreshed when settings change, so drawing code can read them cheaply.

## Activity

- The activity score is a weighted average of ratios to calm: motion, head speed, upper-body movement, and `1 + 4 × hand-near-face fraction`. A calm moment scores about 1, so a threshold of 2.5 means "2.5 times calm".
- Calm baselines are the median of the lowest 30% of per-second averages over 10 minutes. Over-active alerts wait until motion and head speed have about 30 seconds of data. Body pose is often missing (shoulders out of view), so its part stays neutral until it has 30 seconds of data.

## Clips

- The buffer keeps an even 10 fps from the 15 fps stream and trims by time, so a clip is 10 s before the moment plus 4 s after.
- Frames are copied out of the camera's pool into 480x360 YUV buffers (about 26 MB for 14 s). Holding the camera's own buffers would starve its pool.
- Automatic clean-up deletes files right away to free space. Deleting from the Clips window moves files to the Trash.

## Haptics

- MultitouchSupport is loaded with `dlopen` from its fixed system path and never linked. Devices are enumerated with `MTDeviceCreateList` and `MTDeviceGetDeviceID`; the device ID from niw's sample is tried last. Any missing symbol falls back to `NSHapticFeedbackManager`, which needs a finger on the trackpad.

## Menu bar

- Recent macOS versions don't draw `NSMenuItem.image` in status item menus, but they do draw state images in the same column, so icons are set as state images. macOS adds its own icon to the Settings item.

## Data

- Everything lives in `~/Library/Application Support/Steady/` with owner-only permissions (0700). Settings are JSON in `UserDefaults`, laid over the defaults when loaded so new settings never wipe old ones.
- Pausing is not kept across launches; turning monitoring off is.
- `os.Logger` (subsystem `com.arnav.steady`) mirrors the debug event log with plain event descriptions, so `log stream --predicate 'subsystem == "com.arnav.steady"'` shows detections without opening debug mode.

## Developer flags

- `--selftest` runs the checks and exits with 0 or 1.
- `--show` opens windows or triggers actions at launch, for checking layouts: `debug`, `mini`, `settings`, `clips`, `stats`, `smile`, `gaze`, `menu`, `alert`, `session`, `pause`. `--pane <name>` picks the first Settings pane, and `--quality high|balanced|batterySaver` overrides the camera quality without saving it.
