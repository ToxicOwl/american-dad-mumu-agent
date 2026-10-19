# Haptic Alert

`Haptic Alert` is a recognition-only safety guard for the **SUSPICIOUS HAPTIC ACTIVITY** dialog. It uses the fixed title bar and red close icon, not the randomized challenge squares.

## Current Arena behavior

After every completed Arena tournament, before the launcher can start another Food tournament, it takes one read-only screenshot.

- **No alert:** the next tournament may continue normally.
- **Alert detected:** Arena stops, restores `config.json` to monitor mode, saves a screenshot under `captures\haptic-alert`, and starts the configured alert sound in a loop when the sound file exists.
- It **never** solves, dismisses, confirms, or taps the haptic dialog.

## Add your sound

Provide a `.wav` file and place it here:

```text
assets\haptic-alert.wav
```

The default config already points there. After it exists, detected alerts start it automatically in a loop. Use **Stop alert sound** in the app to stop audio only; it does not interact with the game.

## Reuse in future automation

Other automation scripts can run the same guard without sending a tap:

```powershell
.\scripts\haptic-alert.ps1 -Mode CheckCurrent -AdbPath 'C:\Program Files\MuMuPlayer\nx_main\adb.exe' -Device '127.0.0.1:7555'
```

The command returns compact JSON containing `detected`, `score`, `threshold`, and the saved evidence path when a dialog is found.

To stop a running alert sound:

```powershell
.\scripts\haptic-alert.ps1 -Mode StopSound
```
