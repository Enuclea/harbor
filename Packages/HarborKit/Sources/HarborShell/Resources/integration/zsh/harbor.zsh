# Harbor shell integration for zsh.
#
# Reports the working directory (OSC 7) and command boundaries with exit codes
# (OSC 133) so Harbor can open tabs in the same folder, jump between prompts, sync
# the file browser and return command results to AI assistants.

[[ -n "${_HARBOR_INTEGRATION_LOADED-}" ]] && return 0
typeset -g _HARBOR_INTEGRATION_LOADED=1
typeset -gi _harbor_command_running=0

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

_harbor_preexec() {
  builtin print -rn -- $'\e]133;C\a'
  _harbor_command_running=1
}

# Marks where input starts. Runs last so themes that rebuild PS1 keep the mark.
_harbor_mark_prompt_end() {
  [[ "$PS1" == *$'\e]133;B'* ]] || PS1="${PS1}%{"$'\e]133;B\a'"%}"
}

if [[ -n "${HARBOR_PROMPT_FILE-}" && -r "$HARBOR_PROMPT_FILE" ]]; then
  builtin source "$HARBOR_PROMPT_FILE"
fi

typeset -ga precmd_functions preexec_functions
precmd_functions=(_harbor_precmd ${precmd_functions:#(_harbor_precmd|_harbor_mark_prompt_end)} _harbor_mark_prompt_end)
preexec_functions=(${preexec_functions:#_harbor_preexec} _harbor_preexec)

builtin print -rn -- $'\e]1337;HarborShellIntegration=zsh;version=1\a'
