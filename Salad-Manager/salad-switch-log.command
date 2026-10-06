#!/bin/bash
# Salad-Switch-Log launcher for macOS: double-click this file in the Finder.
# It needs PowerShell 7 ("pwsh"). First launch: right-click > Open (Gatekeeper).
cd "$(dirname "$0")" || exit 1

PWSH=""
for candidate in pwsh /opt/homebrew/bin/pwsh /usr/local/bin/pwsh /usr/local/microsoft/powershell/7/pwsh; do
    if command -v "$candidate" >/dev/null 2>&1; then PWSH="$candidate"; break; fi
done

if [ -z "$PWSH" ]; then
    echo
    echo "  PowerShell 7 (pwsh) is not installed on this Mac."
    echo "  Install it with Homebrew:   brew install --cask powershell"
    echo "  or download the .pkg from:  https://github.com/PowerShell/PowerShell/releases"
    echo "  then double-click this file again."
    echo
    read -r -p "  Press Enter to close. "
    exit 1
fi

"$PWSH" -NoProfile -File "./salad-switch-log.ps1" "$@"
status=$?
if [ $status -ne 0 ]; then
    echo
    read -r -p "  Press Enter to close. "
fi
exit $status
