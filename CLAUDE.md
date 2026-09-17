# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file status line for Claude Code itself: `statusline.sh`, symlinked from `~/.claude/statusline.sh` and invoked by the `statusLine` entry in `~/.claude/settings.json`. Claude Code pipes a JSON payload on stdin and prints the rendered bar on stdout. There is no build step and no dependency manifest.

## Commands

```sh
./test.sh        # the whole test suite: one smoke test, prints "ok" or FAIL: <missing string>
./install.sh     # interactive: dependency checks, symlink, settings.json patch
printf '{"model":{"display_name":"Fable"},"effort":{"level":"max"}}' | ./statusline.sh   # render one payload by hand
```

`test.sh` has no framework and no individual test selection. It feeds one payload and greps the ANSI-stripped output for every expected substring, so adding a case means adding a string to the `for want in ...` list.

## Architecture

The script is bash on the outside, python3 on the inside, and the split is deliberate.

**Bash half** collects everything local and fast (git state, terminal width) and exports it as `STATUS_*` environment variables. It also owns the two network-bound segments, which are never fetched synchronously: the weekly Fable quota and the current branch's pull request. Each has its own cache file under `~/.claude/`, a TTL, and a background subshell that refreshes it. The pattern is to `touch` the cache first so a second invocation a moment later does not launch a duplicate fetch, write to `.tmp`, then `mv` into place.

**Python half** is one heredoc-free single-quoted `python3 -c` block that reads the payload from stdin, reads the bash values from the environment, and renders two lines. Because the block is single-quoted, **an apostrophe anywhere inside it terminates the string and breaks the script.** Write comments without contractions or possessives.

Layout of the two lines:

- Line 1 is two powerline groups. The left group chevrons point right, the right group point left, and a computed run of spaces pushes the right group to the terminal edge. `MARGIN = 6` compensates for columns Claude Code trims before it truncates with an ellipsis; it was measured, not derived.
- Line 2 is plain coloured text joined by a separator: pull request, branch with its deltas, session line churn, last commit.

Payload keys the script reads, as built by the Claude Code binary: `model`, `workspace`, `version`, `output_style.name`, `cost.{total_cost_usd,total_duration_ms,total_api_duration_ms,total_lines_added,total_lines_removed}`, `context_window`, `exceeds_200k_tokens`, `fast_mode`, `effort.level`, `thinking.enabled`, `rate_limits.{five_hour,seven_day,spend_limit}`, `vim.mode`, `agent.name`, `remote.session_id`. To re-check them against a new release, grep the binary at `~/.local/share/claude/versions/<v>` for `exceeds_200k_tokens` with surrounding context; the payload is constructed in one object literal there.

Glyph width is a real constraint: line 1 right-aligns by counting characters, so a codepoint the terminal renders double-width shifts the whole bar. `✎` did exactly that and was replaced by `*`. Prefer ASCII for anything new on either line.

The powerline glyphs (`RARR`, `LARR`, `RTHIN`, `LTHIN`) are Nerd Font private-use codepoints written as ``-style escapes. They have been silently emptied by a past bulk edit; `test.sh` now asserts two of them are present, so keep them escaped rather than literal.

Colour constants at the top of the python block are xterm-256 indices, sampled from Claude Code's own UI: `MODEL_BG` from the official per-model colours, `EFFORT_BG` from the effort slider. `fg_for` lists every background light enough to need dark text, so a new light background must be added there too.

Every segment is optional by construction. A missing key, an unparseable timestamp, an absent cache file, or no `gh` all drop that one segment and leave the rest of the bar intact.

## Constraints

- No `jq`, no new dependencies. Hard requirements stay bash, git, python3, curl.
- The Fable quota segment reads Claude Code's OAuth token from `~/.claude/.credentials.json`. It is passed to `curl` through a stdin config file, not as an argument, so it does not appear in `ps`. Keep it that way.
- `curl` uses `-f` so an HTTP error never overwrites a valid cache.
- Known gaps, in case a report touches them: `main..HEAD` is hardcoded so `master` repos get no `+n/main`; the macOS keychain holds the token there, so the Fable segment is empty on macOS.
