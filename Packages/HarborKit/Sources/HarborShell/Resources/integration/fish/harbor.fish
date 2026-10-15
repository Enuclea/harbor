# Harbor shell integration for fish, loaded with `fish --init-command`.
#
# Reports the working directory (OSC 7) and command boundaries with exit codes (OSC 133).

if set -q _HARBOR_INTEGRATION_LOADED
    exit 0
end
set -g _HARBOR_INTEGRATION_LOADED 1

# The display name chosen for this host in Harbor ("Show this name in the prompt and
# tab"). Moved out of LC_* so ssh doesn't carry it on to the next host.
if set -q LC_HARBOR_HOST; and test -n "$LC_HARBOR_HOST"
    set -gx HARBOR_HOST_NAME $LC_HARBOR_HOST
end
set -q LC_HARBOR_HOST; and set -e LC_HARBOR_HOST

# Prompts get the hostname from prompt_hostname; show the chosen name instead.
if set -q HARBOR_HOST_NAME; and test -n "$HARBOR_HOST_NAME"
    function prompt_hostname
        string replace -ra -- '[^[:alnum:] ._+-]' - $HARBOR_HOST_NAME
    end
end

function __harbor_on_prompt --on-event fish_prompt
    printf '\e]7;file://%s%s\e\\' $hostname (string escape --style=url -- $PWD)
    printf '\e]133;A\a'
end

function __harbor_on_preexec --on-event fish_preexec
    printf '\e]1337;HarborCommand=%s\a' (string escape --style=url -- (string sub --length 200 -- "$argv[1]"))
    printf '\e]133;C\a'
end

function __harbor_on_postexec --on-event fish_postexec
    printf '\e]133;D;%s\a' $status
end

if set -q HARBOR_PROMPT_FILE; and test -r "$HARBOR_PROMPT_FILE"
    source "$HARBOR_PROMPT_FILE"
end

printf '\e]1337;HarborShellIntegration=fish;version=3\a'
