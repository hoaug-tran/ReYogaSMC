# Security reports

Do not publish credentials, personal firmware dumps or a working exploit in an ordinary issue. Use GitHub's private vulnerability reporting when enabled. Otherwise open an issue requesting a private contact without including the sensitive details.

Include affected versions, the relevant interface, impact and a minimal reproduction. Hardware shutdown and cooling failures should be reported promptly; stop using the affected control while it is investigated.

ThinkPad fan authorization uses a root launch daemon installed with the system administrator dialog. Its root-owned launch job pins the requesting app's code hash and macOS user. Each XPC request validates the live peer signature using its OS audit token; the kernel matches the entire token, including PID version, against the registered app userclient. Grants end with that userclient and do not permit raw EC access. The helper accepts no shell commands, file paths, firmware offsets or caller-supplied identities. App updates require renewed approval because development packages use ad-hoc signatures.

To remove the persistent authorization, quit ReYogaSMC first so cooling can return to Auto, then run:

```sh
sudo launchctl bootout system/org.reyoga.ReYogaSMC.FanAuthorization
sudo rm -f /Library/LaunchDaemons/org.reyoga.ReYogaSMC.FanAuthorization.plist /Library/PrivilegedHelperTools/org.reyoga.ReYogaSMC.FanAuthorization
```

Removing the app alone does not remove this system authorization. Reinstalling or opening the app again can request approval to reinstall the helper.
