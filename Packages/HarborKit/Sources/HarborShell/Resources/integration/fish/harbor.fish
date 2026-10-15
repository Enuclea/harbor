# Harbor shell integration for fish, loaded with `fish --init-command`.
#
# Reports the working directory (OSC 7) and command boundaries with exit codes (OSC 133).

if set -q _HARBOR_INTEGRATION_LOADED
    exit 0
end
set -g _HARBOR_INTEGRATION_LOADED 1

function __harbor_on_prompt --on-event fish_prompt
    printf '\e]7;file://%s%s\e\\' (prompt_hostname) (string escape --style=url -- $PWD)
    printf '\e]133;A\a'
end

function __harbor_on_preexec --on-event fish_preexec
    printf '\e]133;C\a'
end

function __harbor_on_postexec --on-event fish_postexec
    printf '\e]133;D;%s\a' $status
end

if set -q HARBOR_PROMPT_FILE; and test -r "$HARBOR_PROMPT_FILE"
    source "$HARBOR_PROMPT_FILE"
end

printf '\e]1337;HarborShellIntegration=fish;version=1\a'
