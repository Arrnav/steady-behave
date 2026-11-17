# Security

Steady handles camera data, so privacy and security problems are taken seriously.

## Reporting a problem

Please report security or privacy problems privately through GitHub: open the **Security** tab of this repository and choose **Report a vulnerability**. Don't open a public issue for these.

You can expect a reply within a week.

## Scope

Steady is designed so that:

- it makes no network connections and links only Apple frameworks
- camera frames are processed in memory, and only short clips (if enabled), trained models and daily counters are saved, in `~/Library/Application Support/Steady/`, readable only by your user account
- the camera is off while monitoring is paused, the screen is locked or the Mac sleeps
- the app is signed with the hardened runtime and only the camera entitlement

Saved clips are ordinary video files. Like any file in your home folder, other apps running under your account can read them. Turn clips off in Settings if that matters to you.

Anything that breaks one of these points is in scope.
