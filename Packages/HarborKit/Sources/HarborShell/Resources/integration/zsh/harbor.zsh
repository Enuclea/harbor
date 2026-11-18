# Harbor shell integration for zsh.
#
# Reports the working directory (OSC 7) and command boundaries with exit codes
# (OSC 133) so Harbor can open tabs in the same folder, jump between prompts, sync
# the file browser and return command results to AI assistants.

[[ -n "${_HARBOR_INTEGRATION_LOADED-}" ]] && return 0
typeset -g _HARBOR_INTEGRATION_LOADED=1
typeset -gi _harbor_command_running=0

# The display name chosen for this host in Harbor ("Show this name in the prompt and
# tab"). Moved out of LC_* so ssh doesn't carry it on to the next host.
if [[ -n "${LC_HARBOR_HOST-}" ]]; then
  export HARBOR_HOST_NAME="$LC_HARBOR_HOST"
fi
unset LC_HARBOR_HOST

# Percent-encodes $1 into $REPLY without forking.
_harbor_urlencode() {
  emulate -L zsh
  setopt no_multibyte
  local LC_ALL=C input="$1" output="" char hex
  local -i i
  if [[ "$input" != *[^a-zA-Z0-9/._~-]* ]]; then
    REPLY="$input"
    return
  fi
  for (( i = 1; i <= ${#input}; i++ )); do
    char="${input[i]}"
    case "$char" in
      [a-zA-Z0-9/._~-]) output+="$char" ;;
      *) builtin printf -v hex '%%%02X' "'$char"; output+="$hex" ;;
    esac
  done
  REPLY="$output"
}

_harbor_precmd() {
  local -i last_status=$?
  if (( _harbor_command_running )); then
    builtin print -rn -- $'\e]133;D;'"${last_status}"$'\a'
    _harbor_command_running=0
  fi
  _harbor_urlencode "$PWD"
  builtin print -rn -- $'\e]7;file://'"${HOST}${REPLY}"$'\e\\'
  builtin print -rn -- $'\e]133;A\a'
  return $last_status
}

# $1 is the command line; it's reported (percent-encoded, first 200 characters) so
# Harbor can show what a busy tab is running.
_harbor_preexec() {
  _harbor_urlencode "${1[1,200]}"
  builtin print -rn -- $'\e]1337;HarborCommand='"${REPLY}"$'\a'
  builtin print -rn -- $'\e]133;C\a'
  _harbor_command_running=1
}

# Shows HARBOR_HOST_NAME wherever the prompt shows the hostname (%m, %M). Runs after the
# other precmd functions, so themes that rebuild the prompt every time are covered too.
_harbor_name_prompt() {
  emulate -L zsh
  [[ -n "${HARBOR_HOST_NAME-}" ]] || return 0
  local name="${HARBOR_HOST_NAME//[^[:alnum:] ._+-]/-}"
  PS1="${PS1//\%[mM]/$name}"
  [[ -n "${RPROMPT-}" ]] && RPROMPT="${RPROMPT//\%[mM]/$name}"
  [[ -n "${RPS1-}" ]] && RPS1="${RPS1//\%[mM]/$name}"
  return 0
}

# Marks where input starts. Runs last so themes that rebuild PS1 keep the mark.
_harbor_mark_prompt_end() {
  [[ "$PS1" == *$'\e]133;B'* ]] || PS1="${PS1}%{"$'\e]133;B\a'"%}"
}

if [[ -n "${HARBOR_PROMPT_FILE-}" && -r "$HARBOR_PROMPT_FILE" ]]; then
  builtin source "$HARBOR_PROMPT_FILE"
fi

typeset -ga precmd_functions preexec_functions
precmd_functions=(_harbor_precmd ${precmd_functions:#(_harbor_precmd|_harbor_name_prompt|_harbor_mark_prompt_end)} _harbor_name_prompt _harbor_mark_prompt_end)
preexec_functions=(${preexec_functions:#_harbor_preexec} _harbor_preexec)

_harbor_emit_sysinfo() {
  emulate -L zsh
  local os kern arch distro="" pkg="" init="" tools="" p t is_root="false"
  os=$(uname -s 2>/dev/null)
  kern=$(uname -r 2>/dev/null)
  arch=$(uname -m 2>/dev/null)
  (( EUID == 0 )) && is_root="true"
  if [[ -r /etc/os-release ]]; then
    distro=$(sh -c '. /etc/os-release 2>/dev/null && printf "%s" "${PRETTY_NAME:-$NAME $VERSION_ID}"')
  elif (( $+commands[sw_vers] )); then
    distro="macOS $(sw_vers -productVersion 2>/dev/null)"
  fi
  for p in apt dnf yum apk pacman zypper brew; do
    (( $+commands[$p] )) && { pkg="$p"; break; }
  done
  if (( $+commands[systemctl] )); then init="systemd"
  elif [[ "$os" == "Darwin" ]]; then init="launchd"
  elif (( $+commands[rc-service] )); then init="openrc"
  fi
  for t in git docker podman systemctl journalctl tmux jq rg grep curl python3; do
    (( $+commands[$t] )) && tools="${tools:+$tools,}\"$t\""
  done
  local json="{\"os\":\"${os//\"/}\",\"kernel\":\"${kern//\"/}\",\"arch\":\"${arch//\"/}\",\"distro\":\"${distro//\"/}\",\"hostname\":\"${HOST//\"/}\",\"user\":\"${USER//\"/}\",\"isRoot\":${is_root},\"shell\":\"zsh\",\"packageManager\":\"${pkg}\",\"initSystem\":\"${init}\",\"tools\":[${tools}]}"
  _harbor_urlencode "$json"
  builtin print -rn -- $'\e]1337;HarborSysInfo='"${REPLY}"$'\a'
}

builtin print -rn -- $'\e]1337;HarborShellIntegration=zsh;version=3\a'
_harbor_emit_sysinfo
unfunction _harbor_emit_sysinfo 2>/dev/null || true
