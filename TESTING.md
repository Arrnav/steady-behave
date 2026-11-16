# Testing Steady

## 1. What was built

All five phases are done. Each was built, run through `./build.sh --selftest` (20 checks, all passing), launched, checked in the logs, committed and pushed. Choices that differ from the original plan are listed in [DECISIONS.md](DECISIONS.md).

**Phase 1: menu bar app, camera, Vision, smile, debug mode**
- `build.sh` compiles with `swiftc` (Swift 5 mode, arm64, macOS 14), draws the app icon, signs with the "Apple Development" certificate (found and used on this Mac) and supports `--run`, `--install` and `--selftest`. The app is 4.2 MB.
- Menu bar item and menu, plus global hotkeys ⌃⌥S, ⌃⌥X, ⌃⌥M and ⌃⌥D.
- Camera: built-in camera by default, 640x480 YUV at 15 fps, unmirrored. It stops when paused, locked or asleep (pause verified: "Camera off" one second after pausing).
- Vision per frame: face rectangle and landmarks, hand pose and body pose (each every 3rd frame), and motion energy.
- Personal logistic model, a smile calibration wizard with a live 20 s test, and smile alerts (edge glow, sound, menu bar flash, trackpad haptic).
- False alarm and missed-one feedback with background retraining.
- Debug mode with every overlay layer, readouts, 60 s graphs, tuning sliders, simulated alerts, event log with Copy Log, system stats, and a mini layout.

**Phase 2: looking away**
- Fullscreen moving-dot gaze calibration, then a 15 s look-away step.
- Look-away alerts with grace time, repeats every 15 s (3 at most), no-face handling and an away-from-desk pause.
- Study sessions (25, 50 or 90 min, or open-ended) with the remaining minutes in the menu bar (checked: the book icon showed "24m") and a summary at the end.
- Typing and mouse suppression, auto mode for chosen study apps, quiet mode for Zoom, Teams, FaceTime and Webex, and Quiet for 1 Hour.

**Phase 3: haptics**
- MultitouchSupport is loaded at runtime. Device enumeration finds the M4 Air trackpad (ID `0x7000000000000e2`), and `MTActuatorOpen` and `MTActuatorActuate` return success. NSHapticFeedbackManager is the fallback.
- Settings, Haptics has a Play button for waveforms 1 to 6 and pickers for the smile and look-away patterns.

**Phase 4: activity and clips**
- Activity score from motion, head speed, upper-body movement and hands near the face, compared with your calm level (debug mode shows each part).
- Over-active and hands-at-face alerts.
- Clips: 10 s before and 4 s after, 480x360 H.264 with a JSON sidecar, a clips window with thumbnails, 0.5x and 1x playback, Review Today, Delete Clip, Reveal in Finder and Delete All from This Day.
- Storage limits: 1 clip per 3 min, 25 a day, 500 MB, 14 days.

**Phase 5: stats, settings, privacy**
- Stats window: today's numbers, 7-day bar charts of smiles and look-aways per study hour, and study minutes.
- Open at Login (SMAppService), Settings with eight panes, and Delete All Steady Data.
- Privacy checklist (see the end of this file) and the final README.

**Measured on this Mac** (debug window closed): 11 to 12% of one CPU core at 15 fps. Memory settles at about 196 MB and stayed flat over a 4-minute run. With the debug window open, CPU is about 35 to 45% because of live drawing.

## 2. Commands

```bash
cd ~/git_repos/steady-behave
./build.sh --selftest   # build and run the checks, should print "All checks passed"
./build.sh --install    # build, copy to /Applications/Steady.app and open it
```

Use `--install` for daily use and for Open at Login, which needs the app in /Applications. Use `./build.sh --run` while trying changes.

First launch: the eye icon appears in the menu bar. Camera access is already granted to this signing identity. If macOS asks again, choose Allow.

To follow detections from Terminal:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.arnav.steady"'
```

(Use `/usr/bin/log`; in zsh a plain `log` is a shell builtin.)

## 3. Manual test plan

Do these in order. Each step says what you should see.

1. **Camera access.** Open the menu. You should see "Monitoring: On" with no "Allow Camera Access…" item. The green camera light is on.
2. **Debug mode (⌃⌥D).** Check each overlay checkbox one at a time:
   - Face: box, contour, brows, eyes, pupils as dots, nose, outer and inner lips, mouth corners with a dashed width line.
   - Head pose: the 3-axis gizmo, with yaw, pitch and roll in degrees above the face.
   - Gaze: an arrow from between the eyes. It is green, and turns red when you look far away.
   - Hands: raise a hand. Five finger chains appear, with different colours for left and right.
   - Hand zone: a dashed box around the face and beard. It fills teal when a hand is inside.
   - Body: shoulders, neck and arms.
   - Motion: a warm heatmap where you move.
   - Also check the banner text, the Mirror preview toggle, Keep on Top, Mini View and the System readouts (Frame size should be 640 x 480).
3. **Smile calibration** (menu, Calibrate Smile…, about 1 min). Go through the three steps. On the result screen, an accuracy of 85% or more is good. Click **Test It Now**: the meter should stay low while relaxed and go above the line during the stretched smile.
4. **Smile alert.** Close the calibration window, then do the stretched smile for a second. You should get an orange edge glow, "Relax your face" with your competing response, a Tink sound, a double tap on the trackpad, and an orange menu bar icon. Hold the smile: it repeats after 8 s, 3 times at most.
5. **False alarm (⌃⌥X).** After any smile alert, press ⌃⌥X. The debug event log shows "False alarm: N frames added as relaxed, retraining".
6. **Missed one (⌃⌥M).** Do the smile and press ⌃⌥M while holding it for 1.5 s. The log shows "Missed one: N frames added as smile".
7. **Gaze calibration** (menu, Calibrate Gaze…, about 40 s). Press Space, follow the dot, then look away when asked until the sound plays. Check the accuracy.
8. **10-minute study session.** Use the menu or ⌃⌥S (open the menu's Session Length submenu to pick 25, 50, 90 or open-ended; ⌃⌥S uses the length set in Settings, General). The menu bar shows a book and the minutes left. Look at your phone for 3 s: a blue glow and "Back to the screen". While typing, glancing at the keyboard should not alert. Stop the session from the menu, End Study Session: a summary window shows focus time, look-aways and smiles.
9. **Fidgeting.** Wait about 30 s after launch (the calm level warms up). Then move around a lot for 3 s or more: you should see a purple glow, "Slow down, settle", a quiet Purr, and a clip starts recording. Keep a hand on your beard for 2 s: a teal glow, "Hands down". Keep it there 5 s or more and a clip is saved (at most one clip every 3 minutes).
10. **Haptic test panel** (Settings, Haptics). Press Play for waveforms 1 to 6 with your hand off the trackpad, and choose the ones you like for smile and look-away alerts. If you feel nothing, rest a finger on the trackpad. The Backend line says which method is in use.
11. **Clips window** (menu, Clips…). Clips appear under Today with thumbnails and plain descriptions. Try 0.5x, Review Today, Delete Clip (it goes to the Trash) and Reveal in Finder.
12. **Stats window** (menu, Stats…). Check today's tiles. The per-hour bars appear once a day has 5 minutes or more of study time.
13. **Quiet mode with Zoom or Teams.** Open Zoom or Teams and bring it to the front. The menu shows "Quiet mode: Zoom". Alerts then have no sound or haptic and a smaller, fainter glow. Start a test meeting with video. Both Zoom and Steady should keep the camera; if Zoom shows no video, turn on Settings, Alerts, "Turn the camera off during calls" and tell me.
14. **Pause and lock.** Menu, Pause, 15 Minutes: the camera light goes off and the icon becomes an eye with a slash. Resume. Then lock the screen (⌃⌘Q): the light goes off, and it comes back after you unlock.
15. **Open at Login.** With the app in /Applications, tick Open at Login in the menu. macOS may ask you to approve it in System Settings, Login Items.

## 4. Known limitations and tuning

**Not verified here (needs you in front of the Mac):**
- Whether you can feel the private-API trackpad tap without a finger on the trackpad. The API reports success on this Mac.
- Zoom or Teams using the camera at the same time as Steady. macOS normally allows this, but it was not tested with a live call.
- That `CGEventSource` idle time (used for typing suppression) never brings up an Input Monitoring prompt. Steady never requests that permission.
- The camera light going off on screen lock. The code path is the same as pause, and pause was verified.

**Other notes:**
- This macOS version draws no icons in menu bar menus for any app, so the SF Symbols set on menu items don't show.
- Over-active alerts wait about 30 s after launch while your calm level is learned.
- Gaze calibration covers the main display only.
- Data from test runs during the build is on this Mac: a few over-active and hands-at-face clips, and today's counters. Clear it with Settings, Privacy and Data, Delete All Steady Data if you want a clean start.
- The README hotkey table keeps the wording you gave ("teaches the app it got that one wrong"), even though the wording rules avoid "wrong". Change it if you like.

**What to tune first, in debug mode:**
1. **Smile fires on a normal smile or while talking:** press ⌃⌥X each time (it retrains), or raise Smile threshold from 0.75 toward 0.85. Watch Smoothed p in the Smile classifier box while you talk.
2. **Smile is missed:** press ⌃⌥M while doing it, or lower the threshold toward 0.65. The Expressions bars show which measurement moves; mouth width and corner lift should move clearly away from the relaxed tick.
3. **Look-away alerts while reading the bottom of the screen:** calibrate gaze again and follow the dot all the way into the corners, or raise Gaze threshold to 0.8 or Gaze grace to 4 s.
4. **Over-active fires too easily:** raise Activity threshold (2.5x to 3x). If one part dominates (often Head speed), lower that weight. All parts are shown as ratios to your calm level.
5. **Hands-at-face fires when your hand is on the desk below your chin:** the hand zone reaches 35% of the face height below the face box; check it with the Hand zone layer.
6. **Copy Log** in the event log gives a text record of detections, alerts and suppressed alerts (with reasons) to paste when asking for tuning help.

## Privacy checklist

- No `URLSession`, `http`, `NWConnection` or `Network` in the sources; `nm` and `strings` on the binary show no network symbols; only Apple frameworks are linked (checked with `otool -L`).
- All data is under `~/Library/Application Support/Steady/` (models.json, stats.json, Clips/). Settings, Privacy and Data, Delete All Steady Data removes models, stats and clips after a confirmation.
- The camera stops when monitoring is paused, the screen is locked, the display sleeps or the Mac sleeps.
- The repo contains no clips, models, stats or screenshots (`.gitignore` blocks them, and `git status` was checked before every commit).
