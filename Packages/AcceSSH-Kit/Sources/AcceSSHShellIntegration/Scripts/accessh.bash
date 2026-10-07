# AcceSSH shell integration for bash (bash 3.2 and later).
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

case $- in *i*) ;; *) return 0 ;; esac
[ -n "${__ACCESSH_LOADED:-}" ] && return 0
[ "${ACCESSH_DISABLE_INTEGRATION:-0}" = 1 ] && return 0
__ACCESSH_LOADED=1

__accessh_script_version="1.0.0"
__accessh_hello_sent=0
__accessh_command_running=0
__accessh_at_prompt=0
__accessh_previous_debug_trap=""

__accessh_osc() {
    builtin printf '\033]%s\007' "$1"
}

# Percent-encodes the characters that cannot appear inside an OSC field. Result in REPLY.
__accessh_encode() {
    local __s=$1 __pct='%' __semi=';'
    __s=${__s//"$__pct"/%25}
    __s=${__s//"$__semi"/%3B}
    __s=${__s//$'\a'/%07}
    __s=${__s//$'\e'/%1B}
    __s=${__s//$'\n'/%0A}
    __s=${__s//$'\r'/%0D}
    REPLY=$__s
}

__accessh_send_hello() {
    local __host __user __token
    __accessh_encode "${HOSTNAME:-}"; __host=$REPLY
    __accessh_encode "${USER:-}"; __user=$REPLY
    __accessh_encode "${LC_ACCESSH_TOKEN:-}"; __token=$REPLY
    __accessh_osc "6973;hello;v=1;shell=bash;sv=${__accessh_script_version};caps=prompt,command,exit,commandline,cwd,host,user,notify;host=${__host};user=${__user};token=${__token}"
}

# First entry in PROMPT_COMMAND: report the finished command while $? is still intact.
__accessh_prompt_begin() {
    local __status=$?
    if [ "$__accessh_command_running" = 1 ]; then
        __accessh_osc "133;D;${__status}"
        __accessh_command_running=0
    fi
    if [ "$__accessh_hello_sent" = 0 ]; then
        __accessh_send_hello
        __accessh_hello_sent=1
    fi
    return $__status
}

# Last entry in PROMPT_COMMAND: report the directory and make sure PS1 carries the marks.
# Prompt frameworks that rebuild PS1 on every prompt are re-wrapped each time.
__accessh_prompt_end() {
    local __status=$?
    __accessh_encode "$PWD"
    __accessh_osc "6973;cwd;path=${REPLY}"
    case $PS1 in
        *'133;A'*) ;;
        *) PS1="\[\033]133;A\007\]${PS1}\[\033]133;B\007\]" ;;
    esac
    __accessh_at_prompt=1
    return $__status
}

__accessh_last_history_entry=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null)

# Runs once per submitted command line, from the DEBUG trap (or bash-preexec).
__accessh_preexec() {
    [ "$__accessh_at_prompt" = 1 ] || return 0
    [ -n "${COMP_LINE:-}" ] && return 0
    __accessh_at_prompt=0
    if [ "${ACCESSH_REPORT_COMMAND_LINE:-1}" != 0 ]; then
        local __entry __re='^[[:space:]]*[0-9]+[*]?[[:space:]]+(.*)$'
        __entry=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null)
        # An unchanged history entry means the command was kept out of history
        # (HISTCONTROL=ignorespace, set +o history): respect that and send no text.
        if [ -n "$__entry" ] && [ "$__entry" != "$__accessh_last_history_entry" ] && [[ $__entry =~ $__re ]]; then
            __accessh_last_history_entry=$__entry
            __accessh_encode "${BASH_REMATCH[1]}"
            __accessh_osc "6973;command;cmd=${REPLY}"
        else
            __accessh_osc "6973;command"
        fi
    fi
    __accessh_osc "133;C"
    __accessh_command_running=1
}

__accessh_set_status() { return "$1"; }

__accessh_debug_trap() {
    local __status=$?
    case $BASH_COMMAND in
        __accessh_prompt_begin*|__accessh_prompt_end*) ;;
        *) __accessh_preexec ;;
    esac
    if [ -n "$__accessh_previous_debug_trap" ]; then
        __accessh_set_status "$__status"
        eval "$__accessh_previous_debug_trap"
    fi
    return $__status
}

__accessh_capture_debug_trap() {
    local __current
    __current=$(trap -p DEBUG)
    [ -n "$__current" ] || return 0
    # `trap -p` prints a correctly quoted `trap -- 'command' DEBUG`.
    eval "set -- $__current"
    __accessh_previous_debug_trap=$3
}

if [ -n "${bash_preexec_imported:-}${__bp_imported:-}" ]; then
    # bash-preexec owns PROMPT_COMMAND and the DEBUG trap; register with it instead.
    __accessh_bp_precmd() { __accessh_prompt_begin; __accessh_prompt_end; }
    __accessh_bp_preexec() { __accessh_at_prompt=1; __accessh_preexec; }
    precmd_functions+=(__accessh_bp_precmd)
    preexec_functions+=(__accessh_bp_preexec)
else
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND=(__accessh_prompt_begin "${PROMPT_COMMAND[@]}" __accessh_prompt_end)
    elif [ -n "${PROMPT_COMMAND:-}" ]; then
        PROMPT_COMMAND="__accessh_prompt_begin
${PROMPT_COMMAND}
__accessh_prompt_end"
    else
        PROMPT_COMMAND="__accessh_prompt_begin
__accessh_prompt_end"
    fi
    __accessh_capture_debug_trap
    trap '__accessh_debug_trap' DEBUG
fi

# Lets scripts send an accessible notification: accessh_notify "Build finished" ["Title"]
accessh_notify() {
    local __body __title
    __accessh_encode "${1:-}"; __body=$REPLY
    __accessh_encode "${2:-}"; __title=$REPLY
    __accessh_osc "6973;notify;body=${__body};title=${__title}"
}
