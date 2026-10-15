# Harbor shell integration — bash bootstrap, loaded with `bash --rcfile`.
#
# --rcfile makes bash a non-login shell, so when Harbor asks for a login shell this
# file runs the usual login sequence itself. Your dotfiles are not modified.

if [[ -n "${HARBOR_BASH_LOGIN-}" ]]; then
  unset HARBOR_BASH_LOGIN
  [[ -r /etc/profile ]] && builtin source /etc/profile
  if [[ -r ~/.bash_profile ]]; then
    builtin source ~/.bash_profile
  elif [[ -r ~/.bash_login ]]; then
    builtin source ~/.bash_login
  elif [[ -r ~/.profile ]]; then
    builtin source ~/.profile
  fi
else
  [[ -r ~/.bashrc ]] && builtin source ~/.bashrc
fi

if [[ -r "${HARBOR_SHELL_INTEGRATION_DIR-}/bash/harbor.bash" ]]; then
  builtin source "$HARBOR_SHELL_INTEGRATION_DIR/bash/harbor.bash"
fi
