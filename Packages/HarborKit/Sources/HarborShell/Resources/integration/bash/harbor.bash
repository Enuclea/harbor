# Harbor shell integration for bash.
#
# Reports the working directory (OSC 7) and command boundaries with exit codes
# (OSC 133). Command-start marks need bash 4.4+ (PS0); macOS's bash 3.2 still gets
# directory tracking and prompt marks.

[[ -n "${_HARBOR_INTEGRATION_LOADED-}" ]] && return 0
_HARBOR_INTEGRATION_LOADED=1
_harbor_seen_prompt=0

# Percent-encodes $1 into $REPLY without forking.
_harbor_urlencode() {
  local LC_ALL=C input="$1" output="" char hex i
  for (( i = 0; i < ${#input}; i++ )); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9/._~-]) output+="$char" ;;
      *) printf -v hex '%%%02X' "'$char"; output+="$hex" ;;
    esac
  done
  REPLY="$output"
}

_harbor_prompt_command() {
  local last_status=$?
  if [[ "$_harbor_seen_prompt" == 1 ]]; then
    printf '\e]133;D;%s\a' "$last_status"
  fi
  _harbor_seen_prompt=1
  if declare -F __harbor_prompt_build >/dev/null; then
    __harbor_prompt_build "$last_status"
  fi
  _harbor_urlencode "$PWD"
  printf '\e]7;file://%s%s\e\\' "$HOSTNAME" "$REPLY"
  printf '\e]133;A\a'
  [[ "$PS1" == *'133;B'* ]] || PS1="${PS1}"'\[\e]133;B\a\]'
  return $last_status
}

if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  PS0='\e]133;C\a'"${PS0-}"
fi

if [[ -n "${HARBOR_PROMPT_FILE-}" && -r "$HARBOR_PROMPT_FILE" ]]; then
  builtin source "$HARBOR_PROMPT_FILE"
fi

if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
  PROMPT_COMMAND=(_harbor_prompt_command "${PROMPT_COMMAND[@]}")
else
  PROMPT_COMMAND="_harbor_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi

printf '\e]1337;HarborShellIntegration=bash;version=2\a'
