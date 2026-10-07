# Settings and SSH Keys in AcceSSH

Open **Settings** from the gear button on the host list, or from **Terminal Actions > Settings…** during a session. Every change applies to open sessions immediately.

## VoiceOver and Speech

- **Automatic Reading:** choose how much output is spoken on its own.
  - **Speak new lines** is the default.
  - **Manual reading only** speaks nothing automatically. Use **Read New Output** to hear what arrived.
- **Prompts:** read the prompt text, say a short phrase such as "Prompt", or stay silent.
- **Full-Screen Programs** (nano, vim, htop, menus): hear the newly highlighted item and the cursor line, every changed line, or nothing.
- **Fast Output:**
  - AcceSSH waits for output to go quiet before speaking. During a continuous stream it speaks after the longest wait.
  - When more lines arrive than **Lines at Once**, it reads the last lines, the first lines, or just says how many arrived.
- **Typing:**
  - Commands you type aren't repeated back.
  - Text the shell adds that you didn't type, such as tab completions and history recall, is spoken.
  - Deleted characters are spoken.
- **Command Completion:** choose whether successful commands, failed commands and long-running commands are announced, and whether announcements include the exit status and command name. Exact exit statuses need shell integration.

## Announcements

Turn individual kinds of announcements on or off: connection changes, host key warnings, command completion, command failure, remote notifications and shell integration status.

## Appearance

Choose themes for light and dark mode, font, size, weight, line spacing, character spacing and cursor shape.

Visibility options:
- **Always Use High Contrast**
- **Bold Terminal Text**
- **Make Cursor Easier to See**
- **Mark Colored Text**, which adds a dotted underline so color is never the only signal

Text scales with the system text size unless you turn that off.

## Terminal

Set the terminal type, scrollback length, Delete key behavior and paste confirmation.

You also control what programs on the server may do: change the title, send notifications, and copy text to your clipboard (Ask, Allow or Never). Programs can never read your clipboard.

Command history for the Command field can be kept for the session or not at all. Commands starting with a space, or containing words you list, are never kept.

## Keyboard

**Default Input Mode** sets how sessions start:
- **Automatic** uses Line Editing at the shell prompt and Direct Keys in full-screen programs.
- **Line Editing** always starts with the Command text field.
- **Direct Keys** sends every key straight to the server and announces every character, deletion and cursor move.

A host can use its own mode, under **Input Mode** in the host's settings. During a session you can still switch with **Terminal Actions > Input Mode**; that choice lasts for the session. Password prompts always use a secure text field.

**Option Key Acts as Meta** sends Escape plus the key, for word movement in shells and Emacs.

**Three-Finger Swipes in the Terminal**: with VoiceOver focus in the terminal (on its lines, not the Terminal keys field), a three-finger swipe up, down, left or right sends the matching arrow key. Each direction can be changed to another key (Page Up, Home, Tab, Escape, Control-C and others), an AcceSSH command such as Read New Output, or **Scroll the Terminal** for VoiceOver's normal scrolling. **Restore Arrow Keys** puts the defaults back. If you reversed the scroll direction in VoiceOver's own settings, swap the choices to match.

VoiceOver's Quick Nav uses the arrow keys. To send arrow keys to the server, turn Quick Nav off by pressing Left Arrow and Right Arrow together, or use the arrow buttons in the key bar.

## Key Bar

Reorder, remove and add buttons in the key bar above the keyboard. You can add keys, Control combinations, function keys, AcceSSH commands such as Read New Output, or your own command buttons.

With VoiceOver, swipe up or down on a button and choose **Move Earlier**, **Move Later** or **Remove**.

## Bell

Pick a bell style: Silent, Subtle, Classic Terminal, Haptic Only, Spoken Bell or Strong Alert. Then adjust:
- its sound and volume
- its haptic
- a spoken phrase
- the minimum time between bells
- quiet hours

**Test Bell** plays it. The Haptic section says what this device's hardware supports.

### Your own bell sound

Choose **Import Sound from Files…** in Bell settings and pick a WAV, AIFF, CAF, MP3 or M4A file up to 10 seconds long. AcceSSH keeps its own copy and makes it the bell sound for the selected style.

Imported sounds are listed under **Your Sounds**:
- Activate one to hear it.
- Use the **Use for Bell** or **Delete** actions (swipe up or down with VoiceOver).

If a sound you chose is deleted, the bell plays a short tone instead of going silent.

## SSH Keys

**Generate New Key…** creates a key on this device. Ed25519 is recommended. Optionally, the key can require Face ID or the passcode each time it's used.

Then **Copy Public Key** or **Share Public Key**, and add that line to `~/.ssh/authorized_keys` on your server. The private key stays in this device's Keychain and is never shown or exported.

You can also import an existing private key from Files or by pasting it.

## Trusted Host Keys

These are the servers you've verified. Removing one means you'll be asked to verify its key again on the next connection.
