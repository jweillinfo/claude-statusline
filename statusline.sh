#!/usr/bin/env bash
# Two-line powerline status bar for Claude Code.
#
#   folder > model > effort > ctx      |||   < session < week < fable < cost
#   PR #n title · branch · last commit
#
# ||| is a flexible gap: the right group hugs the terminal's right edge.
# All rendering is done in python3 (no jq).
#
# Two segments hit the network, so they are refreshed in the background with a
# cache: the weekly Fable quota and the current branch's PR. They fail silently
# if a token, curl, gh, or an API format is missing or changes.

input=$(cat)

# --- cwd + git state (local, fast) -----------------------------------------
CWD=$(printf '%s' "$input" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('workspace') or {}).get('current_dir') or d.get('cwd') or '')" 2>/dev/null)
export STATUS_COMMIT=$(git -C "$CWD" log -1 --format='%h %s' 2>/dev/null)
export STATUS_BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
# Deltas: "behind ahead" vs upstream (empty if never pushed), commits ahead of
# main, modified or untracked files.
export STATUS_UPSTREAM=$(git -C "$CWD" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
export STATUS_VS_MAIN=$(git -C "$CWD" rev-list --count main..HEAD 2>/dev/null)
export STATUS_DIRTY=$(( $(git -C "$CWD" status --porcelain 2>/dev/null | wc -l) ))
export STATUS_COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 0)}

# --- Weekly Fable quota: cache refreshed in the background -----------------
FABLE_CACHE="$HOME/.claude/.fable-usage.json"
FABLE_TTL=300
_now=$(date +%s)
_mtime=$( [ -f "$FABLE_CACHE" ] && stat -c %Y "$FABLE_CACHE" 2>/dev/null || echo 0 )
if [ $(( _now - _mtime )) -ge "$FABLE_TTL" ]; then
    touch "$FABLE_CACHE" 2>/dev/null  # claim the slot: no duplicate fetch
    (
        _tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null)
        # -f: a 401/5xx never overwrites a valid cache. The token goes through
        # -K - (stdin) so it does not show up in ps.
        [ -n "$_tok" ] && printf 'header = "Authorization: Bearer %s"\n' "$_tok" \
            | curl -sSf -K - --max-time 8 "https://api.anthropic.com/api/oauth/usage" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -o "$FABLE_CACHE.tmp" 2>/dev/null \
            && mv "$FABLE_CACHE.tmp" "$FABLE_CACHE" 2>/dev/null
        rm -f "$FABLE_CACHE.tmp"
    ) >/dev/null 2>&1 &
fi
export FABLE_CACHE

# --- Current branch's PR: cache refreshed in the background ----------------
# gh hits the network, so it is never called synchronously. headRefName is
# stored so python only shows the PR when it matches the displayed branch.
# One cache per repo: two repos with a same-named branch do not mix.
_repo=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null | md5sum | cut -c1-8)
PR_CACHE="$HOME/.claude/.pr-cache-${_repo:-none}.json"
PR_TTL=60
_pmtime=$( [ -f "$PR_CACHE" ] && stat -c %Y "$PR_CACHE" 2>/dev/null || echo 0 )
if [ $(( _now - _pmtime )) -ge "$PR_TTL" ]; then
    touch "$PR_CACHE" 2>/dev/null
    (
        # The branch is passed explicitly: otherwise gh follows branch.<name>.merge,
        # which sometimes points at main.
        _out=$( [ -n "$STATUS_BRANCH" ] && cd "$CWD" 2>/dev/null && gh pr view "$STATUS_BRANCH" --json number,title,headRefName,state,isDraft 2>/dev/null)
        printf '%s' "${_out:-{\}}" > "$PR_CACHE.tmp" 2>/dev/null \
            && mv "$PR_CACHE.tmp" "$PR_CACHE" 2>/dev/null
    ) >/dev/null 2>&1 &
fi
export PR_CACHE

printf '%s' "$input" | python3 -c '
import sys, json, os, time, re

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

RARR = ""   # powerline chevron pointing right
LARR = ""   # powerline chevron pointing left
RTHIN = ""  # thin variants, between two identical backgrounds
LTHIN = ""
THIN_FG = 243
RESET = "\033[0m"

# --- Official Claude colours per model, in xterm-256 -----------------------
# Fable blue #5B8DEF->69, Opus salmon #E8967A->209, Sonnet ivory #F0EEE6->255,
# Haiku sage #A8C4B8->151
MODEL_BG = {"fable": 69, "opus": 209, "sonnet": 255, "haiku": 151}
# Effort: same colours as the effort slider of Claude Code (low gold, medium
# green, xhigh lavender). high and max are interpolated: max is a more
# saturated lavender.
EFFORT_BG = {"low": 220, "medium": 114, "high": 117, "xhigh": 147, "max": 141}
FOLDER_BG = 25    # deep blue
AGENT_BG  = 55    # purple, sub-agent or remote session
VIM_BG    = 22    # dark green, vim NORMAL mode
STYLE_BG  = 238   # grey, non-default output style
GAUGE_BG  = 236   # dark grey, shared by all gauges
LABEL_FG  = 245   # muted label on grey
COST_FG   = 250

# Fill gradient: the colour only tints the dot and the %, warming up towards 100 %.
LEVELS = ((25, 78), (50, 148), (70, 220), (85, 208), (95, 203))

def level_colour(p):
    if p is None:
        return 240
    for threshold, colour in LEVELS:
        if p < threshold:
            return colour
    return 196   # bright red

def fg_for(bg):
    return 232 if bg in (209, 255, 151, 220, 114, 117, 147, 141) else 231

def pill(text, bg, fg=None):
    fg = fg if fg is not None else fg_for(bg)
    return (text, fg, bg)

# Gauge: grey background, muted label, dot + % in the level colour.
# Inline fg codes do not touch the bg set by the pill.
def gauge(label, p, suffix="", alert=False):
    col = 196 if alert else level_colour(p)
    bold = "\033[1m" if alert else ""
    txt = (f"{bold}\033[38;5;{col}m●\033[38;5;{LABEL_FG}m {label} "
           f"{bold}\033[38;5;{col}m{round(p)}%\033[22m\033[38;5;{LABEL_FG}m")
    if suffix:
        txt += f" {suffix}"
    return pill(txt, GAUGE_BG, LABEL_FG)

def strip(s):
    return re.sub(r"\033\[[0-9;]*m", "", s)

def vlen(s):
    return len(strip(s))

# Left group: chevrons pointing right, transition bg_i -> bg_(i+1)
def powerline_left(segs):
    out = ""
    for i, (text, fg, bg) in enumerate(segs):
        out += f"\033[38;5;{fg}m\033[48;5;{bg}m {text} "
        nbg = segs[i + 1][2] if i + 1 < len(segs) else None
        if nbg == bg:
            out += f"\033[38;5;{THIN_FG}m{RTHIN}"
        else:
            tail = f"\033[48;5;{nbg}m" if nbg is not None else "\033[49m"
            out += f"\033[38;5;{bg}m{tail}{RARR}"
    return out + RESET

# Right group: chevrons pointing left, transition from the previous segment
# (terminal background before the first one).
def powerline_right(segs):
    out = ""
    prev = None
    for text, fg, bg in segs:
        if prev == bg:
            out += f"\033[38;5;{THIN_FG}m{LTHIN}"
        else:
            head = f"\033[48;5;{prev}m" if prev is not None else "\033[49m"
            out += f"\033[38;5;{bg}m{head}{LARR}"
        out += f"\033[38;5;{fg}m\033[48;5;{bg}m {text} "
        prev = bg
    return out + RESET

def fmt_reset(epoch, fmt):
    try:
        return time.strftime(fmt, time.localtime(int(epoch))) if epoch else ""
    except (TypeError, ValueError):
        return ""

def fmt_duration(ms):
    try:
        mins = int(ms) // 60000
    except (TypeError, ValueError):
        return ""
    if mins < 1:
        return ""
    return f"{mins // 60}h{mins % 60:02d}" if mins >= 60 else f"{mins}m"

# ===========================================================================
# LINE 1
# ===========================================================================
left = []

# folder
ws = d.get("workspace") or {}
cwd = ws.get("current_dir") or d.get("cwd") or ""
base = os.path.basename(cwd.rstrip("/")) or "~"
left.append(pill(base, FOLDER_BG))

# vim NORMAL mode: only worth showing when it blocks typing (INSERT is the default)
vim = (d.get("vim") or {}).get("mode")
if vim and vim.upper() != "INSERT":
    left.append(pill(vim.upper(), VIM_BG))

# model
model = (d.get("model") or {}).get("display_name") or (d.get("model") or {}).get("id") or "?"
mbg = next((v for k, v in MODEL_BG.items() if k in model.lower()), 173)
left.append(pill(model, mbg))

# fast mode rides on the model pill rather than taking its own segment
if d.get("fast_mode"):
    left.append(pill("fast", mbg))

# effort
effort = (d.get("effort") or {}).get("level")
if effort:
    left.append(pill(effort, EFFORT_BG.get(effort.lower(), 173)))

# sub-agent or remote session: whose session this actually is
agent = (d.get("agent") or {}).get("name")
if agent:
    left.append(pill(agent[:20], AGENT_BG))
elif (d.get("remote") or {}).get("session_id"):
    left.append(pill("remote", AGENT_BG))

# output style, only when it is not the plain default
style = (d.get("output_style") or {}).get("name")
if style and style.lower() not in ("default", "null"):
    left.append(pill(style[:16], STYLE_BG))

# context. Past 90 % auto-compaction is close, so the gauge goes bold red
# regardless of the gradient; exceeds_200k_tokens gets a marker of its own.
ctx = (d.get("context_window") or {}).get("used_percentage")
if ctx is not None:
    warn = "!" if d.get("exceeds_200k_tokens") else ""
    left.append(gauge("ctx", ctx, warn, alert=ctx >= 90))

right = []
rl = d.get("rate_limits") or {}
fh = rl.get("five_hour") or {}
sd = rl.get("seven_day") or {}

# session: % -> reset time
if fh.get("used_percentage") is not None:
    end = fmt_reset(fh.get("resets_at"), "%H:%M")
    right.append(gauge("sess", fh["used_percentage"], f"→ {end}" if end else ""))

# week: % -> reset day and hour
if sd.get("used_percentage") is not None:
    when = fmt_reset(sd.get("resets_at"), "%-d %b %Hh")
    right.append(gauge("wk", sd["used_percentage"], f"→ {when}" if when else ""))

# fable: weekly quota (fails silently)
try:
    with open(os.environ["FABLE_CACHE"]) as f:
        for lim in (json.load(f).get("limits") or []):
            if ((lim.get("scope") or {}).get("model") or {}).get("display_name") == "Fable":
                pf = lim.get("percent")
                if pf is not None:
                    right.append(gauge("fable", pf))
                break
except Exception:
    pass

cost = d.get("cost") or {}

# wall-clock session duration
dur = fmt_duration(cost.get("total_duration_ms"))
if dur:
    right.append(pill(dur, GAUGE_BG, LABEL_FG))

# cost
usd = cost.get("total_cost_usd")
if usd:
    right.append(pill(f"${usd:.2f}", GAUGE_BG, COST_FG))

pl = powerline_left(left)
pr = powerline_right(right) if right else ""

try:
    cols = int(os.environ.get("STATUS_COLS") or 0)
except ValueError:
    cols = 0
if cols <= 0:
    cols = 120
# Claude Code passes the raw terminal width but trims a few columns (padding +
# gutter) before truncating with "…". 3 was not enough; 6 measured as safe,
# at the cost of an invisible gap on the right.
MARGIN = 6
gap = max(2, cols - MARGIN - vlen(pl) - vlen(pr))
line1 = pl + (" " * gap) + pr

# ===========================================================================
# LINE 2: PR · branch · last commit
# ===========================================================================
def c(code, s):
    return f"\033[{code}m{s}{RESET}"

# branch (git rev-parse, computed in bash: keeps the fix/, feat/ prefix)
branch = os.environ.get("STATUS_BRANCH") or None
if branch == "HEAD":
    branch = "detached HEAD"

segs = []

# PR: only if the cache matches the displayed branch
try:
    with open(os.environ["PR_CACHE"]) as f:
        pr_info = json.load(f)
    if pr_info.get("number") and pr_info.get("headRefName") == branch:
        title = (pr_info.get("title") or "")[:44]
        num = pr_info["number"]
        # GitHub colours: open green, draft grey, merged purple, closed red
        state = "DRAFT" if pr_info.get("isDraft") else (pr_info.get("state") or "OPEN")
        col = {"OPEN": 78, "DRAFT": 245, "MERGED": 135, "CLOSED": 196}.get(state, 78)
        segs.append(c(f"1;38;5;{col}", f"⌥ #{num} {title}".rstrip()))
except Exception:
    pass

if branch:
    deltas = []
    up = (os.environ.get("STATUS_UPSTREAM") or "").split()
    if len(up) == 2:
        behind, ahead = int(up[0]), int(up[1])
        if ahead:  deltas.append(c("38;5;208", f"↑{ahead}"))    # unpushed
        if behind: deltas.append(c("38;5;75",  f"↓{behind}"))   # to pull
    else:
        deltas.append(c("38;5;208", "↑∅"))                      # never pushed
    vs_main = os.environ.get("STATUS_VS_MAIN") or "0"
    if branch != "main" and vs_main != "0":
        deltas.append(c("38;5;78", f"+{vs_main}/main"))
    dirty = os.environ.get("STATUS_DIRTY") or "0"
    if dirty != "0":
        deltas.append(c("38;5;220", f"*{dirty}"))
    segs.append(c("33", branch) + (" " + " ".join(deltas) if deltas else ""))

# session diff size, ASCII only: the width of +/- is never ambiguous
added = cost.get("total_lines_added") or 0
removed = cost.get("total_lines_removed") or 0
if added or removed:
    churn = []
    if added:
        churn.append(c("38;5;78", f"+{added}"))
    if removed:
        churn.append(c("38;5;203", f"-{removed}"))
    segs.append(" ".join(churn))

commit = os.environ.get("STATUS_COMMIT") or ""
if commit:
    sha, _, subject = commit.partition(" ")
    segs.append(c("90", sha) + " " + c("2;37", subject[:60]))

line2 = c("90", "  ·  ").join(segs)

sys.stdout.write(line1 + ("\n" + line2 if line2 else ""))
'
