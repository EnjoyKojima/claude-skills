#!/bin/bash
# Claude Code statusline script (with rate limit usage)
# Line 1: Model | Context% | +added/-removed | git branch
# Line 2: 5h rate limit progress bar
# Line 3: 7d rate limit progress bar
# Line 4: model-scoped weekly limit (e.g. Fable) progress bar
#
# 2〜4行目には使用率に加えて「ペース差分」（本来の消費ペースとの差、緑=余裕/赤=超過）と
# リセットまでの残り時間を表示する。
#
# 5h/7d のレートリミット情報はHaiku probeのレスポンスヘッダーから取得。
# 結果は /tmp/claude-usage-cache.json に360秒キャッシュ。
# モデル別週次枠（Fable等）は OAuth usage API から取得し、
# /tmp/claude-model-usage-cache.json に60秒キャッシュ（更新はバックグラウンド）。
# 依存: jq / curl。認証情報は macOS Keychain または ~/.claude/.credentials.json から取得。

input=$(cat)

# ---------- ANSI Colors ----------
GREEN=$'\e[38;2;151;201;195m'
PACE_GREEN=$'\e[38;2;152;195;121m'
YELLOW=$'\e[38;2;229;192;123m'
RED=$'\e[38;2;224;108;117m'
GRAY=$'\e[38;2;74;88;92m'
RESET=$'\e[0m'
DIM=$'\e[2m'

# ---------- Color by percentage ----------
color_for_pct() {
  local pct="$1"
  if [ -z "$pct" ] || [ "$pct" = "null" ]; then
    printf '%s' "$GRAY"
    return
  fi
  local ipct
  ipct=$(printf "%.0f" "$pct" 2>/dev/null || echo "0")
  if [ "$ipct" -ge 80 ]; then
    printf '%s' "$RED"
  elif [ "$ipct" -ge 50 ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

# ---------- Progress bar (10 segments) ----------
progress_bar() {
  local pct="$1"
  local filled
  filled=$(awk "BEGIN{printf \"%d\", int($pct / 10 + 0.5)}" 2>/dev/null || echo 0)
  [ "$filled" -gt 10 ] 2>/dev/null && filled=10
  [ "$filled" -lt 0 ] 2>/dev/null && filled=0
  local bar=""
  for i in $(seq 1 10); do
    if [ "$i" -le "$filled" ]; then
      bar="${bar}▰"
    else
      bar="${bar}▱"
    fi
  done
  printf '%s' "$bar"
}

# ---------- Pace indicator ----------
# ウィンドウ開始 (= reset - window長) からの経過時間割合を「本来のペース」とし、
# 実使用% との差分のみを表示する（例: -13% = ペースより13pt余裕 / +18% = 超過）。
# ペース以下=緑 / ペース超過=赤。
pace_display() {
  local used="$1" reset_epoch="$2" window="$3"
  if [ -z "$used" ] || [ -z "$reset_epoch" ] || [ "$reset_epoch" = "0" ]; then
    return
  fi
  local now start elapsed pace diff color sign
  now=$(date +%s)
  start=$((reset_epoch - window))
  elapsed=$((now - start))
  [ "$elapsed" -lt 0 ] && elapsed=0
  [ "$elapsed" -gt "$window" ] && elapsed=$window
  pace=$((elapsed * 100 / window))
  diff=$((used - pace))
  if [ "$diff" -le 0 ]; then
    color="$PACE_GREEN"
  else
    color="$RED"
  fi
  sign=""
  [ "$diff" -gt 0 ] && sign="+"
  printf '%s%s%s%%%s' "$color" "$sign" "$diff" "$RESET"
}

# ---------- Remaining time until reset (e.g. "1h23m") ----------
remaining_until() {
  local epoch="$1"
  [ -z "$epoch" ] || [ "$epoch" = "0" ] && return
  local now diff d h m
  now=$(date +%s)
  diff=$((epoch - now))
  [ "$diff" -lt 0 ] && diff=0
  d=$((diff / 86400))
  h=$((diff % 86400 / 3600))
  m=$((diff % 3600 / 60))
  if [ "$d" -gt 0 ]; then
    printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

# ---------- Parse stdin (single jq call) ----------
eval "$(echo "$input" | jq -r '
  "model_name=" + (.model.display_name // "Unknown" | @sh),
  "used_pct=" + (.context_window.used_percentage // 0 | tostring),
  "cwd=" + (.cwd // "" | @sh),
  "lines_added=" + (.cost.total_lines_added // 0 | tostring),
  "lines_removed=" + (.cost.total_lines_removed // 0 | tostring),
  "cc_version=" + (.version // "0.0.0" | @sh)
' 2>/dev/null)"

# ---------- Git branch ----------
git_branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

# ---------- Line stats from stdin ----------
git_stats=""
if [ "$lines_added" -gt 0 ] 2>/dev/null || [ "$lines_removed" -gt 0 ] 2>/dev/null; then
  git_stats="+${lines_added}/-${lines_removed}"
fi

# ---------- Rate limit via Haiku probe (cached 360s) ----------
CACHE_FILE="/tmp/claude-usage-cache.json"
CACHE_TTL=360
FIVE_HOUR_UTIL=""
FIVE_HOUR_RESET=""
SEVEN_DAY_UTIL=""
SEVEN_DAY_RESET=""

# macOS: Keychain / Linux: ~/.claude/.credentials.json
get_access_token() {
  local token
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  if [ -z "$token" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    token=$(cat "$HOME/.claude/.credentials.json")
  fi
  [ -z "$token" ] && return 1

  local access_token
  if echo "$token" | jq -e . >/dev/null 2>&1; then
    access_token=$(echo "$token" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  else
    access_token="$token"
  fi
  [ -z "$access_token" ] && return 1
  printf '%s' "$access_token"
}

fetch_usage() {
  local access_token
  access_token=$(get_access_token) || return 1

  # Tiny Haiku call (max_tokens=1) to get rate limit response headers
  local full_response
  full_response=$(curl -sD- --max-time 8 -o /dev/null \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/${cc_version:-0.0.0}" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"h"}]}' \
    "https://api.anthropic.com/v1/messages" 2>/dev/null || true)
  local headers="$full_response"
  [ -z "$headers" ] && return 1

  # Parse rate limit headers
  local h5_util h5_reset h7_util h7_reset
  h5_util=$(echo "$headers" | grep -i 'anthropic-ratelimit-unified-5h-utilization' | tr -d '\r' | awk '{print $2}')
  h5_reset=$(echo "$headers" | grep -i 'anthropic-ratelimit-unified-5h-reset' | tr -d '\r' | awk '{print $2}')
  h7_util=$(echo "$headers" | grep -i 'anthropic-ratelimit-unified-7d-utilization' | tr -d '\r' | awk '{print $2}')
  h7_reset=$(echo "$headers" | grep -i 'anthropic-ratelimit-unified-7d-reset' | tr -d '\r' | awk '{print $2}')

  [ -z "$h5_util" ] && return 1

  # Save to cache as JSON
  jq -n \
    --arg h5u "$h5_util" --arg h5r "$h5_reset" \
    --arg h7u "$h7_util" --arg h7r "$h7_reset" \
    '{five_hour_util: $h5u, five_hour_reset: $h5r, seven_day_util: $h7u, seven_day_reset: $h7r}' \
    > "$CACHE_FILE"
  return 0
}

load_usage() {
  local data="$1"
  eval "$(echo "$data" | jq -r '
    "FIVE_HOUR_UTIL=" + (.five_hour_util // empty),
    "FIVE_HOUR_RESET=" + (.five_hour_reset // empty),
    "SEVEN_DAY_UTIL=" + (.seven_day_util // empty),
    "SEVEN_DAY_RESET=" + (.seven_day_reset // empty)
  ' 2>/dev/null)"
}

# Check cache validity (stat: BSD/macOS -f, GNU/Linux -c)
USE_CACHE=false
if [ -f "$CACHE_FILE" ]; then
  cache_mtime=$(stat -f '%m' "$CACHE_FILE" 2>/dev/null || stat -c '%Y' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_age=$(( $(date +%s) - cache_mtime ))
  if [ "$cache_age" -lt "$CACHE_TTL" ]; then
    USE_CACHE=true
  fi
fi

if $USE_CACHE; then
  load_usage "$(cat "$CACHE_FILE")"
else
  if fetch_usage; then
    load_usage "$(cat "$CACHE_FILE")"
  elif [ -f "$CACHE_FILE" ]; then
    load_usage "$(cat "$CACHE_FILE")"
  fi
fi

# Convert utilization (0.0-1.0) to percentage
to_pct() {
  local val="$1"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo ""
    return
  fi
  awk "BEGIN{printf \"%.0f\", $val * 100}" 2>/dev/null || echo ""
}

FIVE_HOUR_PCT=$(to_pct "$FIVE_HOUR_UTIL")
SEVEN_DAY_PCT=$(to_pct "$SEVEN_DAY_UTIL")

# ---------- Model-scoped weekly usage (e.g. Fable) via OAuth usage API ----------
# Haiku probe のヘッダーにはモデル別枠が無いため、OAuth usage API
# (https://api.anthropic.com/api/oauth/usage) の limits[] から kind=weekly_scoped
# （モデルスコープ付き週次枠）を取得する。
# 描画をブロックしないよう、TTL切れ時はバックグラウンドで更新して既存キャッシュを表示する。
MODEL_USAGE_CACHE="/tmp/claude-model-usage-cache.json"
MODEL_USAGE_TTL=60

refresh_model_usage_cache() {
  local access_token resp tmp
  access_token=$(get_access_token) || return

  resp=$(curl -sS --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer ${access_token}" \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return

  tmp=$(mktemp "/tmp/.claude-model-usage.XXXXXX") || return
  if echo "$resp" | jq -e '
      [.limits[]? | select(.kind == "weekly_scoped" and .scope.model != null)][0]
      | {label: (.scope.model.display_name // "Model"), pct: .percent, resets_at: .resets_at}
    ' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$MODEL_USAGE_CACHE"
  else
    rm -f "$tmp"
  fi
}

model_cache_age=$MODEL_USAGE_TTL
if [ -f "$MODEL_USAGE_CACHE" ]; then
  model_cache_mtime=$(stat -f '%m' "$MODEL_USAGE_CACHE" 2>/dev/null || stat -c '%Y' "$MODEL_USAGE_CACHE" 2>/dev/null || echo 0)
  model_cache_age=$(( $(date +%s) - model_cache_mtime ))
fi
if [ "$model_cache_age" -ge "$MODEL_USAGE_TTL" ]; then
  ( refresh_model_usage_cache ) </dev/null >/dev/null 2>&1 &
fi

MODEL_SCOPED_LABEL=""
MODEL_SCOPED_PCT=""
MODEL_SCOPED_RESET_ISO=""
if [ -f "$MODEL_USAGE_CACHE" ]; then
  eval "$(jq -r '
    "MODEL_SCOPED_LABEL=" + ((.label // "") | @sh),
    "MODEL_SCOPED_PCT=" + ((.pct // "") | tostring | @sh),
    "MODEL_SCOPED_RESET_ISO=" + ((.resets_at // "") | tostring | @sh)
  ' "$MODEL_USAGE_CACHE" 2>/dev/null)"
fi

# ---------- Format reset time (from epoch seconds) ----------
STATUSLINE_TZ="${STATUSLINE_TZ:-Asia/Tokyo}"
format_epoch_time() {
  local epoch="$1"
  local format="$2"
  [ -z "$epoch" ] || [ "$epoch" = "0" ] && echo "" && return
  local result
  result=$(LC_ALL=C TZ="$STATUSLINE_TZ" date -j -f "%s" "$epoch" "$format" 2>/dev/null || \
           LC_ALL=C TZ="$STATUSLINE_TZ" date -d "@${epoch}" "$format" 2>/dev/null || echo "")
  echo "$result" | sed 's/AM/am/;s/PM/pm/'
}

five_reset_display=""
if [ -n "$FIVE_HOUR_RESET" ] && [ "$FIVE_HOUR_RESET" != "0" ]; then
  five_reset_display="Resets $(format_epoch_time "$FIVE_HOUR_RESET" "+%-I%p") (${STATUSLINE_TZ}) · in $(remaining_until "$FIVE_HOUR_RESET")"
fi

seven_reset_display=""
if [ -n "$SEVEN_DAY_RESET" ] && [ "$SEVEN_DAY_RESET" != "0" ]; then
  seven_reset_display="Resets $(format_epoch_time "$SEVEN_DAY_RESET" "+%b %-d at %-I%p") (${STATUSLINE_TZ}) · in $(remaining_until "$SEVEN_DAY_RESET")"
fi

# ---------- Format context used% ----------
ctx_pct_int=0
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ] && [ "$used_pct" != "0" ]; then
  ctx_pct_int=$(printf "%.0f" "$used_pct" 2>/dev/null || echo 0)
fi

# ---------- Line 1 ----------
SEP="${GRAY} │ ${RESET}"
ctx_color=$(color_for_pct "$ctx_pct_int")

line1="🤖 ${model_name}${SEP}${ctx_color}📊 ${ctx_pct_int}%${RESET}"

if [ -n "$git_stats" ]; then
  line1+="${SEP}✏️  ${GREEN}${git_stats}${RESET}"
fi

if [ -n "$git_branch" ]; then
  line1+="${SEP}🔀 ${git_branch}"
fi

# ---------- Line 2 (5h) ----------
line2=""
if [ -n "$FIVE_HOUR_PCT" ]; then
  c5=$(color_for_pct "$FIVE_HOUR_PCT")
  bar5=$(progress_bar "$FIVE_HOUR_PCT")
  line2="${c5}⏱ 5h  ${bar5}  ${FIVE_HOUR_PCT}%${RESET}"
  pace5=$(pace_display "$FIVE_HOUR_PCT" "$FIVE_HOUR_RESET" $((5 * 3600)))
  [ -n "$pace5" ] && line2+="  ${pace5}"
  [ -n "$five_reset_display" ] && line2+="  ${DIM}${five_reset_display}${RESET}"
else
  line2="${GRAY}⏱ 5h  ▱▱▱▱▱▱▱▱▱▱  --%${RESET}"
fi

# ---------- Line 3 (7d) ----------
line3=""
if [ -n "$SEVEN_DAY_PCT" ]; then
  c7=$(color_for_pct "$SEVEN_DAY_PCT")
  bar7=$(progress_bar "$SEVEN_DAY_PCT")
  line3="${c7}📅 7d  ${bar7}  ${SEVEN_DAY_PCT}%${RESET}"
  pace7=$(pace_display "$SEVEN_DAY_PCT" "$SEVEN_DAY_RESET" $((7 * 86400)))
  [ -n "$pace7" ] && line3+="  ${pace7}"
  [ -n "$seven_reset_display" ] && line3+="  ${DIM}${seven_reset_display}${RESET}"
else
  line3="${GRAY}📅 7d  ▱▱▱▱▱▱▱▱▱▱  --%${RESET}"
fi

# ---------- Line 4 (model-scoped weekly, e.g. Fable) ----------
line4=""
model_scoped_label="${MODEL_SCOPED_LABEL:-Model}"
if [ -n "$MODEL_SCOPED_PCT" ] && [ "$MODEL_SCOPED_PCT" != "null" ]; then
  MODEL_SCOPED_PCT=$(printf "%.0f" "$MODEL_SCOPED_PCT" 2>/dev/null || echo "")
fi
if [ -n "$MODEL_SCOPED_PCT" ]; then
  cm=$(color_for_pct "$MODEL_SCOPED_PCT")
  barm=$(progress_bar "$MODEL_SCOPED_PCT")
  line4="${cm}✨ ${model_scoped_label}  ${barm}  ${MODEL_SCOPED_PCT}%${RESET}"
  # resets_at は ISO 8601 (UTC)。秒までに切り詰めて epoch へ変換し 7d と同じ書式で表示
  model_reset_iso="${MODEL_SCOPED_RESET_ISO%%.*}"
  if [ -n "$model_reset_iso" ]; then
    model_reset_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$model_reset_iso" "+%s" 2>/dev/null || \
                        date -u -d "$model_reset_iso" "+%s" 2>/dev/null || echo "")
    if [ -n "$model_reset_epoch" ]; then
      pacem=$(pace_display "$MODEL_SCOPED_PCT" "$model_reset_epoch" $((7 * 86400)))
      [ -n "$pacem" ] && line4+="  ${pacem}"
      line4+="  ${DIM}Resets $(format_epoch_time "$model_reset_epoch" "+%b %-d at %-I%p") (${STATUSLINE_TZ}) · in $(remaining_until "$model_reset_epoch")${RESET}"
    fi
  fi
fi

# ---------- RunCat Neo custom metrics (opt-in) ----------
# RunCat Neo のカスタムメトリクス連携。RUNCAT_CLAUDE_OUT_FILE を設定した場合のみ書き出す。
write_runcat_snapshot() {
  local out_file="${RUNCAT_CLAUDE_OUT_FILE:-}"
  [ -z "$out_file" ] && return
  local out_dir tmp_file updated_at

  out_dir=$(dirname "$out_file")
  mkdir -p "$out_dir" || return
  tmp_file=$(mktemp "${out_dir}/.runcat-usage.XXXXXX") || return
  updated_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

  if ! jq -n \
    --arg model "$model_name" \
    --arg context "${used_pct:-}" \
    --arg five "${FIVE_HOUR_PCT:-}" \
    --arg seven "${SEVEN_DAY_PCT:-}" \
    --arg updated "$updated_at" '
      def percentage_metric($title; $value):
        if ($value | test("^[0-9]+([.][0-9]+)?$")) then
          ($value | tonumber) as $number
          | {
              title: $title,
              formattedValue: (($number | tostring) + "%"),
              normalizedValue: (
                ($number / 100)
                | if . < 0 then 0 elif . > 1 then 1 else . end
              )
            }
        else empty end;

      {
        title: "Claude Code",
        symbol: "staroflife",
        metrics: [
          {title: "Model", formattedValue: $model},
          percentage_metric("Context"; $context),
          percentage_metric("5h"; $five),
          percentage_metric("7d"; $seven)
        ],
        lastUpdatedDate: $updated
      }
      + if ($five | test("^[0-9]+([.][0-9]+)?$")) then
          {metricsBarValue: ("5h " + $five + "%")}
        elif ($seven | test("^[0-9]+([.][0-9]+)?$")) then
          {metricsBarValue: ("7d " + $seven + "%")}
        elif ($context | test("^[0-9]+([.][0-9]+)?$")) then
          {metricsBarValue: ("Ctx " + $context + "%")}
        else {} end
    ' > "$tmp_file"; then
    rm -f "$tmp_file"
    return
  fi

  mv "$tmp_file" "$out_file"
}

write_runcat_snapshot 2>/dev/null || true

# ---------- Output ----------
printf '%s\n' "$line1"
printf '%s\n' "$line2"
if [ -n "$line4" ]; then
  printf '%s\n' "$line3"
  printf '%s' "$line4"
else
  printf '%s' "$line3"
fi
