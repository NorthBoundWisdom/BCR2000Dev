#!/bin/zsh
set -eu
if [[ -r "$HOME/.config/dev-environment/environment.sh" ]]; then
    source "$HOME/.config/dev-environment/environment.sh"
fi
root="${0:A:h}"
if ! command -v python3 >/dev/null 2>&1; then
    print -u2 "Python 3.9+ is required; no packages or system settings were changed."
    exit 69
fi
cd "$root"
exec python3 "$root/macos_test_session.py" "$@"
