# AcceSSH shell integration for fish (fish 3.1 and later).
# Protocol version 1. Script version 1.0.0.
#
# What this does: prints invisible terminal escape sequences that tell AcceSSH where
# prompts, commands and command output begin and end, the exit status of each command,
# and the current directory. AcceSSH uses them for VoiceOver navigation and
# announcements. Nothing is sent anywhere except to your own terminal.
#
# Opt-outs:
#   ACCESSH_DISABLE_INTEGRATION=1   do not load at all
#   ACCESSH_REPORT_COMMAND_LINE=0   never report command text (marks and exit status only)

if status is-interactive; and not set -q __accessh_loaded; and test "$ACCESSH_DISABLE_INTEGRATION" != 1
    set -g __accessh_loaded 1
    set -g __accessh_script_version 1.0.0
    set -g __accessh_hello_sent 0
    set -g __accessh_command_running 0

    function __accessh_osc
        printf '\e]%s\a' $argv[1]
    end

    # Percent-encodes the characters that cannot appear inside an OSC field.
    function __accessh_encode
        printf '%s' $argv[1] | string replace -a '%' '%25' | string replace -a ';' '%3B' \
            | string replace -a \a '%07' | string replace -a \e '%1B' | string replace -a \r '%0D' \
            | string join '%0A'
    end

    function __accessh_return
        return $argv[1]
    end

    function __accessh_on_prompt --on-event fish_prompt
        if test $__accessh_hello_sent = 0
            set -l host (__accessh_encode "$hostname")
            set -l user (__accessh_encode "$USER")
            set -l token (__accessh_encode "$LC_ACCESSH_TOKEN")
            __accessh_osc "6973;hello;v=1;shell=fish;sv=$__accessh_script_version;caps=prompt,command,exit,commandline,cwd,host,user,notify;host=$host;user=$user;token=$token"
            set -g __accessh_hello_sent 1
        end
        set -l cwd (__accessh_encode "$PWD")
        __accessh_osc "6973;cwd;path=$cwd"
    end

    function __accessh_preexec --on-event fish_preexec
        if test "$ACCESSH_REPORT_COMMAND_LINE" != 0
            set -l cmd (__accessh_encode "$argv[1]")
            __accessh_osc "6973;command;cmd=$cmd"
        end
        __accessh_osc "133;C"
        set -g __accessh_command_running 1
    end

    function __accessh_postexec --on-event fish_postexec
        set -l exit_status $status
        if test $__accessh_command_running = 1
            __accessh_osc "133;D;$exit_status"
            set -g __accessh_command_running 0
        end
    end

    # Wrap the prompt with prompt marks, preserving $status for prompts that display it.
    if functions -q fish_prompt; and not functions -q __accessh_original_fish_prompt
        functions -c fish_prompt __accessh_original_fish_prompt
        function fish_prompt
            set -l last_status $status
            printf '\e]133;A\a'
            __accessh_return $last_status
            __accessh_original_fish_prompt
            printf '\e]133;B\a'
        end
    end

    # Lets scripts send an accessible notification: accessh_notify "Build finished" ["Title"]
    function accessh_notify
        set -l body (__accessh_encode "$argv[1]")
        set -l title (__accessh_encode "$argv[2]")
        __accessh_osc "6973;notify;body=$body;title=$title"
    end
end
