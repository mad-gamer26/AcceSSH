# AcceSSH Shell-Integration Protocol (version 1)

The shell-integration protocol lets a remote shell tell AcceSSH exactly where prompts, commands and output are, the exit status of each command, and the working directory. It is optional. AcceSSH works without it, using heuristics. With it, semantic navigation and announcements are exact.

Implementation: `Packages/AcceSSH-Kit/Sources/AcceSSHShellIntegration` (decoder, scripts, installer) and `Sources/AcceSSHTerminal/SemanticModel.swift` (how messages become command records).

## Transport

Messages are OSC (Operating System Command) escape sequences written to the terminal by the shell:

```
ESC ] <code> ; <payload> BEL        (BEL = 0x07)
ESC ] <code> ; <payload> ESC \      (ST)
```

They travel on the existing PTY, so they need no network service and work through `sudo -i`, nested SSH and serial consoles. Other terminals ignore unknown OSC codes.

## Marks: OSC 133 (shared convention)

| Sequence | Meaning | Emitted by AcceSSH scripts |
|---|---|---|
| `OSC 133 ; A [; k=i\|c\|s\|r]` | Prompt starts at the cursor | in PS1 / fish_prompt |
| `OSC 133 ; B` | Prompt ends; command input starts | in PS1 / fish_prompt |
| `OSC 133 ; C` | Command submitted; output starts | preexec |
| `OSC 133 ; D [; <exit status>]` | Command finished | precmd / fish_postexec |

OSC 633 (VS Code: `A`, `B`, `C`, `D`, `E;<commandline>`, `P;Cwd=<path>`) and OSC 7 (`file://host/path`) are also understood. This means a host already set up for another terminal's integration gets accurate navigation in AcceSSH too. Its state is reported as **marks only**.

## Metadata: OSC 6973 (AcceSSH)

```
ESC ] 6973 ; <event> [; <key>=<value>]* BEL
```

Values are percent-encoded. At minimum, `%`, `;`, and the control characters BEL, ESC, CR and LF are encoded. Other UTF-8 passes through. Keys appear at most once, and the first occurrence wins.

| Event | Fields | Meaning |
|---|---|---|
| `hello` | `v` protocol version, `shell`, `sv` script version, `caps`, `host`, `user`, `token` | Handshake; sent once, at the first prompt |
| `command` | `cmd` (optional) | Exact command line about to run. `cmd` is omitted when the shell keeps the command out of history (bash `HISTCONTROL=ignorespace`, zsh `HIST_IGNORE_SPACE`) or when `ACCESSH_REPORT_COMMAND_LINE=0` |
| `cwd` | `path` | Working directory (after every command) |
| `host` / `user` | `name` | Host or user changed |
| `title` | `text` | Title text |
| `notify` | `body`, `title`, `urgency` (`low`/`normal`/`critical`) | Accessible notification, sent by `accessh_notify "message" ["title"]` |
| `output-start` / `output-end` | — | Explicit output-block bounds for programs that are not shells |

`caps` is a comma-separated list: `prompt, command, exit, commandline, cwd, host, user, notify, output, title`.

### Versioning and compatibility

- `v` is an integer. AcceSSH implements version 1.
- A newer version from the remote side puts integration in the **newer protocol** state. Known messages are still used, and the person is told to update AcceSSH.
- Unknown events and unknown keys are ignored. New fields can therefore be added without a version bump; only incompatible meaning changes bump `v`.
- `sv` (script version) is compared with the bundled script version to offer updates.

### Trust model

Any program can print these sequences, for example `cat` of a file containing them. To tell the integration script apart, AcceSSH sends a random per-session token in `LC_ACCESSH_TOKEN`. OpenSSH's default `AcceptEnv LANG LC_*` passes it. A `hello` echoing the token marks the session **verified**.

Spoofed marks can only mislead navigation and announcements inside that session. They can never trigger local actions, clipboard reads, file access or network access. Payloads are limited to 8 KiB, and text fields are sanitized and capped before display or speech.

## Semantics in AcceSSH

| Message | Effect on the model |
|---|---|
| A | Closes a running command with unknown status if D was missed. A redraw of the same prompt row reuses the existing record. Otherwise a new `TerminalCommand` is created (phase `prompt`) |
| B | `inputStart` = cursor; phase `input` |
| `command;cmd=` | Pending command line, attached at C |
| C | `outputStart` = cursor; command line = reported text or text between B and C; phase `running`; `commandStarted` event |
| D;n | `outputEnd` = cursor; `exitStatus` = n; phase `finished`; `commandFinished` event (drives "Command finished with exit status 1.") |
| `cwd` | Updates the working directory and the current record |

Marks received on the alternate screen are ignored, because shells never draw prompts there.

## Installation

The scripts live under `~/.accessh/shell-integration/accessh.{bash,zsh,fish}` on the remote host. Loading them is opt-in, in one of two ways:

1. **Activate on connect**: after login AcceSSH types ` . ~/.accessh/shell-integration/accessh.<shell>`, with a leading space to stay out of history. No startup file is changed.
2. **Startup-file block** (approved by the person after reviewing the full diff). For example:

```sh
# >>> AcceSSH shell integration >>>
# Added by AcceSSH with your approval. It loads accessibility shell integration
# (prompt, command and exit-status marks for VoiceOver). To remove it, delete this
# block or use Shell Integration > Remove in AcceSSH.
if [ "${LC_TERMINAL:-}" = "AcceSSH" ] && [ -r "$HOME/.accessh/shell-integration/accessh.bash" ]; then
    . "$HOME/.accessh/shell-integration/accessh.bash"
fi
# <<< AcceSSH shell integration <<<
```

The installer replaces only the text between the markers. A file with a begin marker but no end marker, or with two blocks, is refused rather than guessed at. Over SSH, bash usually reads `~/.bash_profile`, so the block is also proposed there when that file does not already load `~/.bashrc`.

## Script behavior notes

- **bash:**
  - Marks come from `PROMPT_COMMAND` (first and last entries, preserving `$?` and the array form of bash 5.1+).
  - Preexec comes from a DEBUG trap that chains to any existing trap. When `bash-preexec` is loaded, the script registers with it instead.
  - PS1 is re-wrapped whenever a prompt framework rebuilds it.
- **zsh:** `precmd_functions` (status capture first, marks last) and `preexec_functions`. PS1 is wrapped with `%{…%}` so the marks have zero width.
- **fish:** `fish_prompt`, `fish_preexec` and `fish_postexec` events, plus a `fish_prompt` wrapper that preserves `$status`. fish 4 emits OSC 133 natively; duplicate marks are idempotent.
- **All shells:**
  - Each script loads only in interactive shells and only once.
  - `ACCESSH_DISABLE_INTEGRATION=1` turns a script off.
  - `ACCESSH_REPORT_COMMAND_LINE=0` keeps command text private.
