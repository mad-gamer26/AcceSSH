# AcceSSH shell integration for zsh (zsh 5.0 and later).
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

[[ -o interactive ]] || return 0
(( ${+__ACCESSH_LOADED} )) && return 0
[[ "${ACCESSH_DISABLE_INTEGRATION:-0}" == 1 ]] && return 0
typeset -g __ACCESSH_LOADED=1

typeset -g __accessh_script_version="1.0.0"
typeset -g __accessh_hello_sent=0
typeset -g __accessh_command_running=0

__accessh_osc() {
    builtin printf '\033]%s\007' "$1"
}

# Percent-encodes the characters that cannot appear inside an OSC field. Result in REPLY.
__accessh_encode() {
    emulate -L zsh
    local s=$1 pct='%'
    s=${s//$pct/%25}
    s=${s//;/%3B}
    s=${s//$'\a'/%07}
    s=${s//$'\e'/%1B}
    s=${s//$'\n'/%0A}
    s=${s//$'\r'/%0D}
    typeset -g REPLY=$s
}

__accessh_send_hello() {
    local host user token
    __accessh_encode "${HOST:-}"; host=$REPLY
    __accessh_encode "${USER:-}"; user=$REPLY
    __accessh_encode "${LC_ACCESSH_TOKEN:-}"; token=$REPLY
    __accessh_osc "6973;hello;v=1;shell=zsh;sv=${__accessh_script_version};caps=prompt,command,exit,commandline,cwd,host,user,notify;host=${host};user=${user};token=${token}"
}

# First precmd hook: report the finished command while $? is still intact.
__accessh_precmd_status() {
    local exit_status=$?
    if (( __accessh_command_running )); then
        __accessh_osc "133;D;${exit_status}"
        __accessh_command_running=0
    fi
    if (( ! __accessh_hello_sent )); then
        __accessh_send_hello
        __accessh_hello_sent=1
    fi
    return $exit_status
}

# Last precmd hook: report the directory and make sure the prompt carries the marks.
# Themes that rebuild PS1 in their own precmd are re-wrapped each time.
__accessh_precmd_marks() {
    __accessh_encode "$PWD"
    __accessh_osc "6973;cwd;path=${REPLY}"
    if [[ $PS1 != *'133;A'* ]]; then
        PS1=$'%{\e]133;A\a%}'"${PS1}"$'%{\e]133;B\a%}'
    fi
}

__accessh_preexec() {
    if [[ "${ACCESSH_REPORT_COMMAND_LINE:-1}" != 0 ]]; then
        # Honor HIST_IGNORE_SPACE: a command hidden from history is not reported either.
        if [[ -o histignorespace && $1 == ' '* ]]; then
            __accessh_osc "6973;command"
        else
            __accessh_encode "$1"
            __accessh_osc "6973;command;cmd=${REPLY}"
        fi
    fi
    __accessh_osc "133;C"
    __accessh_command_running=1
}

typeset -ga precmd_functions preexec_functions
precmd_functions=(__accessh_precmd_status ${precmd_functions:#__accessh_*} __accessh_precmd_marks)
preexec_functions+=(__accessh_preexec)

# Lets scripts send an accessible notification: accessh_notify "Build finished" ["Title"]
accessh_notify() {
    local body title
    __accessh_encode "${1:-}"; body=$REPLY
    __accessh_encode "${2:-}"; title=$REPLY
    __accessh_osc "6973;notify;body=${body};title=${title}"
}
