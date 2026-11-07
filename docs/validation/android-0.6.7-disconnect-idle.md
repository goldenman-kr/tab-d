# Android 0.6.7 explicit-disconnect validation

Date: 2026-11-08 (Asia/Seoul)

Environment: Android 16 tablet connected by USB, MacBook Pro M4 running installed Mac 0.6.6. USB uses ADB reverse; wireless uses paired-host discovery and LAN TLS. Existing application data and pairing were preserved during APK update installation.

## Build and static checks

- `bash scripts/build-android.sh :app:protocolCheck :app:lintDebug`: successful.
- 143 existing checks passed: updater policy 31, framing 9, decoder selection 5, tap 9, input gestures 16, double tap 20, scroll 21, recovery gate 32.
- Android lint: no issues found.
- Device regression script syntax and `git diff --check`: passed.

## Device regression

Command: `python3 scripts/test-android-disconnect-idle.py --serial <authorized-device> --routes usb wireless`

For each transport:

1. Pressed its explicit connection button; received and rendered monitor frames.
2. Opened the control bar with Back and pressed disconnect.
3. Observed acknowledged stop: no connected/authenticated channel, no discovery, connection work disabled, no pending stop request, no retained display or fullscreen monitor.
4. Observed stopped state for 10 seconds (longer than several former 2.5-second retry/ping intervals).
5. Returned from Android Home; state remained stopped.
6. Force-stopped and relaunched the app; state remained stopped.
7. Pressed the connection button again; monitor frames resumed. Disconnected again and left the tablet stopped.

Initial test setup encountered a tablet keyguard/notification-shade input interception and an inactive Mac server/missing USB reverse path. After screen sleep/wake, launching the installed Mac app and restoring the Tab-D reverse mapping, the full regression ran successfully. These setup issues did not require weakening stopped-state behavior.

## Scope and limits

This verifies connection state and the app's work gate, not a measured battery drain percentage or zero device-wide power consumption. It does not measure long overnight standby or fault-inject the five-second disconnect timeout/TLS setup cancellation paths. GitHub update checks at app startup remain independent of Mac session communication. Home/pause during an active monitor session retains the existing resume behavior.

Mac code and its 0.6.6 DMG are unchanged in this release. The same DMG is included with Android 0.6.7 for complete installation downloads.
