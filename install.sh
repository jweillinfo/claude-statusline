#!/usr/bin/env bash
# Interactive installer: checks dependencies, links the script, patches settings.json.
set -u
here=$(cd "$(dirname "$0")" && pwd)
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
ask()  { read -rp "  $1 [y/N] " a; [[ ${a,,} == y* ]]; }

echo "Dependencies"
for dep in bash git python3 curl; do
    command -v "$dep" >/dev/null && ok "$dep" || { warn "$dep missing (required)"; missing=1; }
done
[ -n "${missing:-}" ] && { echo "Install the missing tools first (Debian/Ubuntu: sudo apt install git python3 curl)."; exit 1; }

# gh: optional, only for the PR segment
if gh_path=$(command -v gh); then
    case "$gh_path" in
        /mnt/*|*.exe)
            warn "gh resolves to the Windows binary ($gh_path)."
            warn "On WSL that one is slow (Windows interop) and uses the Windows login, not this shell's."
            warn "Install the Linux gh from GitHub's apt repo so it comes first in PATH.";;
        *) ok "gh $(gh --version | head -1 | cut -d' ' -f3) at $gh_path"
           gh auth status >/dev/null 2>&1 || warn "gh is not logged in: run 'gh auth login' (PR segment stays empty until then)";;
    esac
else
    warn "gh not found: the PR segment will be empty."
    if [ -f /etc/debian_version ] && ask "Install gh from GitHub's official apt repo (Ubuntu's own package is outdated)?"; then
        sudo mkdir -p -m 755 /etc/apt/keyrings \
        && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
        && sudo apt update && sudo apt install -y gh && ok "gh installed, now run: gh auth login"
    fi
fi

echo "Font"
warn "Powerline chevrons need a Nerd Font in your terminal (https://www.nerdfonts.com). Windows Terminal: Settings > Profile > Appearance > Font face."

echo "Link"
target="$HOME/.claude/statusline.sh"
if [ -e "$target" ] && [ ! -L "$target" ]; then
    ask "$target exists and is not a symlink. Back it up to $target.bak and replace?" || exit 1
    mv "$target" "$target.bak"
fi
ln -sfn "$here/statusline.sh" "$target" && ok "$target -> $here/statusline.sh"

echo "Settings"
python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys, os
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
want = {"type": "command", "command": "~/.claude/statusline.sh", "padding": 1}
if d.get("statusLine") == want:
    print("  \033[32m✓\033[0m statusLine already configured")
else:
    d["statusLine"] = want
    json.dump(d, open(p, "w"), indent=2); print("  \033[32m✓\033[0m statusLine written to", p)
PY
echo "Done. Restart Claude Code."
