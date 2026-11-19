# Testing

## Automated checks

```bash
./build.sh --selftest   # builds the app and runs the built-in checks, no camera needed
swiftlint lint          # style and common mistakes (brew install swiftlint)
shellcheck build.sh     # shell script checks
```

`--selftest` covers:

- the logistic model on a separable dataset (over 95% accuracy) and saving and loading it
- expression features staying the same when a face is scaled or rolled, and changing when the mouth widens
- the gaze feature vector
- writing a 3 s clip and the full 10 s + 4 s clip recorder flow with its sidecar
- saving and reloading stats, clip retention and the size cap
- alert hold time, cooldown and the 3-repeat limit with a fake clock
- look-away grace time, typing suppression and the missing-face rules
- the hand-near-face zone, upper-body movement and the calm baseline
- settings defaults, deleting all data, alert color parsing and detection switches
- which haptics backend loads

CI runs the self-test, SwiftLint and a network-symbol check on every push and pull request.

## Manual test plan

Run these on a MacBook with a built-in camera after `./build.sh --run`.

1. **Camera access.** Allow camera access. The menu shows "Monitoring: On" and the camera light is on.
2. **Debug mode (⌃⌥D).** Turn on each overlay: face landmarks, head pose gizmo, gaze arrow (green on screen, red when looking away), hand skeletons, the dashed hand zone (fills when a hand is inside), body skeleton and motion heatmap. Check that Frame size reads 640 x 480.
3. **Expression calibration.** Run Calibrate Expression, then Test It Now. The meter stays low when relaxed and rises during the stretched expression.
4. **Expression alert.** Hold the stretched expression. An edge glow, the "Relax your face" label, a sound and a trackpad tap appear, repeating after the cooldown up to 3 times.
5. **Feedback hotkeys.** ⌃⌥X after an alert and ⌃⌥M during a expression each add an entry to the debug event log and retrain.
6. **Gaze calibration.** Follow the dot, look away when asked, check the accuracy.
7. **Study session.** Start one with ⌃⌥S. The menu bar shows the minutes left. Looking away for a few seconds gives a look-away alert; typing does not. Ending the session shows a summary.
8. **Activity.** After about 30 s, move a lot for 3 s (over-active alert and a clip), then keep a hand at your chin for 2 s (hands-at-face alert).
9. **Detections.** Turn one detection off under Detections in the menu. Its alerts stop and the debug window shows it as off.
10. **Colors.** Change a glow color in Settings > Alerts and use Show Test Alert.
11. **Haptics.** Settings > Haptics plays waveforms 1 to 6.
12. **Clips and stats.** The Clips window lists saved clips with thumbnails and plays them at 0.5x and 1x. The Stats window shows today's counts.
13. **Camera quality.** Switch Settings > General > Camera > Quality and check the debug window's Quality and Frames per second readouts. Unplug the charger: within 10 seconds Battery Saver is in use. Step out of view for 10 seconds: the readout shows Idle. Stay out of view and don't touch the Mac for a minute: the camera light goes off and the menu says the camera is off while you're away; pressing a key turns it back on.
14. **Repeated habits.** Settings > Repeated Habits: Test Blur blurs the screen for a moment without blocking clicks; Test Voice speaks a sample reminder. Trigger the same habit three times within 10 minutes and the screen blurs until it stops.
15. **Keyboard and trackpad.** Settings > General > Keyboard and Trackpad: with Stretched Expression not paused, a expression while typing still alerts; with it paused, it doesn't.
16. **Calls.** With FaceTime, Zoom or Teams in front, alerts are silent and fainter.
17. **Camera off.** Pausing, locking the screen and sleeping each turn the camera light off; it comes back afterwards.
