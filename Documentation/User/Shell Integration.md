# Shell Integration in AcceSSH

Shell integration is an optional, small script for your server's shell (bash, zsh or fish). It makes AcceSSH's VoiceOver features exact.

## What it gives you

Without shell integration, AcceSSH guesses where prompts and commands are by looking for common prompt endings such as `$`, `#` and `%`. With it, your shell tells AcceSSH directly. That makes these features reliable:

- **Jump to Previous Command** and **Jump to Next Command**
- **Read Last Command** and **Read Last Command Output**, which read only that command's output, not the whole screen
- **Copy Last Command Output**
- Announcements such as "Command failed with exit status 1." You choose whether successful commands are announced too, and whether long-running commands are announced when they finish.
- Searching within one command's output
- Knowing the current directory

## What it does not do

The script only prints invisible codes to your own terminal. It does not send anything over the network, does not run in scripts or cron jobs (only in interactive shells), and does not change how your shell behaves.

## Installing, updating and removing

While connected, open **Terminal Actions > Shell Integration…**. The screen shows:

- **In This Session:** whether integration is active, with its shell, script version, whether it's verified, and what it reports. If it's installed but not running yet, **Activate Now** loads it without changing any files.
- **On This Server:** your login shell, the installed version, and which startup file loads it. **Install…**, **Update…** and **Remove…** first show a review of every file that will change, with every added or removed line (VoiceOver reads each as "Line 3 of 9" followed by the code). Nothing changes until you confirm. If a file changes on the server after you reviewed it, nothing is changed and you're asked to review again.
- **Load:** "Only in AcceSSH sessions" (the default) or "In every interactive shell", for servers that don't pass the `LC_TERMINAL` variable.
- **For This Host:** "When the server provides it", "Activate on connect" (loads the installed script each time you connect, without editing startup files) or "Off".
- **Troubleshooting:** advice based on what AcceSSH finds, such as an unsupported shell, a script that's installed but not running, or an available update.

Changed startup files are backed up once, the first time AcceSSH edits them, as `<file>.accessh-backup` (for example `~/.bashrc.accessh-backup`). The change is one clearly marked block that starts with `# >>> AcceSSH shell integration >>>` and ends with `# <<< AcceSSH shell integration <<<`. **Remove** deletes exactly that block and AcceSSH's own folder, `~/.accessh`; you can also delete them yourself.

## Privacy controls

- Commands you start with a space are not reported when your shell is set to keep them out of history.
- Set `ACCESSH_REPORT_COMMAND_LINE=0` in your shell to stop reporting command text entirely. Prompts, output boundaries and exit statuses still work.
- Set `ACCESSH_DISABLE_INTEGRATION=1` to turn the script off without uninstalling it.

## Notifications from your own scripts

With shell integration active, `accessh_notify "Backup finished" "Server"` sends an accessible notification. VoiceOver speaks it, and it can also play a sound or haptic you assign.
