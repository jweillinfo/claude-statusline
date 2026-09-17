#!/usr/bin/env bash
# Smoke test: feed a sample payload, assert every segment renders and a bad resets_at does not kill the line.
cd "$(dirname "$0")"
out=$(printf '{"model":{"display_name":"Fable 5.1"},"effort":{"level":"max"},"fast_mode":true,"vim":{"mode":"NORMAL"},"agent":{"name":"Explore"},"output_style":{"name":"Ponytail"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":93},"exceeds_200k_tokens":true,"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":"not-a-number"},"seven_day":{"used_percentage":14,"resets_at":1758258000}},"cost":{"total_cost_usd":0.78,"total_duration_ms":4980000,"total_lines_added":12,"total_lines_removed":3}}' "$PWD" | ./statusline.sh | sed 's/\x1b\[[0-9;]*m//g')
for want in "claude-statusline" "" "" "Fable 5.1" "max" "fast" "NORMAL" "Explore" "Ponytail" "ctx 93%" "sess 15%" "wk 14% → " "1h23" "\$0.78" "+12" "-3" "main"; do
    grep -q -- "$want" <<<"$out" || { echo "FAIL: missing '$want'"; echo "$out"; exit 1; }
done
echo "ok"
