#!/usr/bin/env bash

# FSDeltaMonitor: 实时磁盘空间增长监测（零第三方依赖）
# 依赖: bash, du, find, stat, awk, sort, head, tput, date

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"

SCAN_PATH=""
MODE="dir"
DEPTH=2
INTERVAL=2
TOP_N=10
ONCE=0
NO_COLOR=0

declare -a INCLUDE_PATTERNS=()
declare -a EXCLUDE_PATTERNS=()

TMP_ROOT="/tmp"
if [[ ! -d "$TMP_ROOT" ]]; then
  TMP_ROOT="/var/tmp"
fi
if [[ ! -d "$TMP_ROOT" ]]; then
  TMP_ROOT="."
fi

HAS_TTY=0
if [[ -t 1 ]]; then
  HAS_TTY=1
fi

COLOR_RESET=""
COLOR_TITLE=""
COLOR_WARN=""
COLOR_GOOD=""
COLOR_MUTED=""

init_colors() {
  if [[ "$NO_COLOR" -eq 1 || "$HAS_TTY" -ne 1 ]]; then
    return
  fi
  COLOR_RESET=$'\033[0m'
  COLOR_TITLE=$'\033[1;36m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_GOOD=$'\033[1;32m'
  COLOR_MUTED=$'\033[0;37m'
}

print_help() {
  cat <<'EOF'
FSDeltaMonitor - Linux 磁盘空间增长实时监测（零第三方依赖）

用法:
  bash fsdelta.sh --path <PATH> [选项]

必填参数:
  --path <PATH>            监测目标路径（目录或文件）

选项:
  --mode <dir|file|auto>   监测模式，默认 dir
  --depth <N>              目录扫描深度，默认 2（仅 dir 模式生效）
  --interval <SEC>         扫描间隔（秒），默认 2
  --top <N>                显示增长 Top N，默认 10
  --include <PATTERN>      包含路径模式，可重复传入（shell glob）
  --exclude <PATTERN>      排除路径模式，可重复传入（shell glob）
  --once                   执行一轮并退出
  --no-color               关闭颜色输出
  --help                   显示帮助

示例:
  bash fsdelta.sh --path /data --mode dir --depth 3 --interval 2 --top 20
  bash fsdelta.sh --path /var/log/syslog --mode auto --once
  bash fsdelta.sh --path /data --mode dir --include "/data/app/*" --exclude "*/cache/*"
EOF
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        [[ $# -lt 2 ]] && { echo "ERROR: --path 缺少参数"; exit 1; }
        SCAN_PATH="$2"
        shift 2
        ;;
      --mode)
        [[ $# -lt 2 ]] && { echo "ERROR: --mode 缺少参数"; exit 1; }
        MODE="$2"
        shift 2
        ;;
      --depth)
        [[ $# -lt 2 ]] && { echo "ERROR: --depth 缺少参数"; exit 1; }
        DEPTH="$2"
        shift 2
        ;;
      --interval)
        [[ $# -lt 2 ]] && { echo "ERROR: --interval 缺少参数"; exit 1; }
        INTERVAL="$2"
        shift 2
        ;;
      --top)
        [[ $# -lt 2 ]] && { echo "ERROR: --top 缺少参数"; exit 1; }
        TOP_N="$2"
        shift 2
        ;;
      --include)
        [[ $# -lt 2 ]] && { echo "ERROR: --include 缺少参数"; exit 1; }
        INCLUDE_PATTERNS+=("$2")
        shift 2
        ;;
      --exclude)
        [[ $# -lt 2 ]] && { echo "ERROR: --exclude 缺少参数"; exit 1; }
        EXCLUDE_PATTERNS+=("$2")
        shift 2
        ;;
      --once)
        ONCE=1
        shift
        ;;
      --no-color)
        NO_COLOR=1
        shift
        ;;
      --help|-h)
        print_help
        exit 0
        ;;
      *)
        echo "ERROR: 未知参数: $1"
        print_help
        exit 1
        ;;
    esac
  done
}

validate_args() {
  if [[ -z "$SCAN_PATH" ]]; then
    echo "ERROR: --path 为必填参数"
    exit 1
  fi
  if [[ ! -e "$SCAN_PATH" ]]; then
    echo "ERROR: 路径不存在: $SCAN_PATH"
    exit 1
  fi
  case "$MODE" in
    dir|file|auto) ;;
    *)
      echo "ERROR: --mode 仅支持 dir|file|auto"
      exit 1
      ;;
  esac
  if ! is_uint "$DEPTH"; then
    echo "ERROR: --depth 必须为非负整数"
    exit 1
  fi
  if ! is_uint "$INTERVAL" || [[ "$INTERVAL" -lt 1 ]]; then
    echo "ERROR: --interval 必须为正整数"
    exit 1
  fi
  if ! is_uint "$TOP_N" || [[ "$TOP_N" -lt 1 ]]; then
    echo "ERROR: --top 必须为正整数"
    exit 1
  fi
}

resolve_mode() {
  if [[ "$MODE" == "auto" ]]; then
    if [[ -f "$SCAN_PATH" ]]; then
      MODE="file"
    else
      MODE="dir"
    fi
  fi
}

path_allowed() {
  local p="$1"
  local ok_include=1
  local pattern

  if [[ "${#INCLUDE_PATTERNS[@]}" -gt 0 ]]; then
    ok_include=0
    for pattern in "${INCLUDE_PATTERNS[@]}"; do
      if [[ "$p" == $pattern ]]; then
        ok_include=1
        break
      fi
    done
  fi
  [[ "$ok_include" -eq 0 ]] && return 1

  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ "$p" == $pattern ]]; then
      return 1
    fi
  done

  return 0
}

human_size() {
  local bytes="$1"
  awk -v b="$bytes" '
    function h(x,   i,units) {
      split("B KiB MiB GiB TiB PiB", units, " ")
      i = 1
      while (x >= 1024 && i < 6) {
        x = x / 1024
        i++
      }
      if (i == 1) {
        return sprintf("%.0f %s", x, units[i])
      }
      return sprintf("%.1f %s", x, units[i])
    }
    BEGIN { print h(b) }
  '
}

truncate_path() {
  local p="$1"
  local max_len="$2"
  local len="${#p}"
  if [[ "$len" -le "$max_len" ]]; then
    printf "%s" "$p"
    return
  fi
  local keep=$((max_len - 3))
  printf "%s..." "${p:0:keep}"
}

repeat_char() {
  local ch="$1"
  local count="$2"
  local i
  for ((i = 0; i < count; i++)); do
    printf "%s" "$ch"
  done
}

screen_clear() {
  if command -v tput >/dev/null 2>&1; then
    tput clear 2>/dev/null || printf '\033[2J\033[H'
  else
    printf '\033[2J\033[H'
  fi
}

read_quit_key() {
  local key=""
  if [[ -t 0 ]]; then
    IFS= read -r -n 1 -t 0.05 key || return 1
    [[ "$key" == "q" || "$key" == "Q" ]] && return 0
  fi
  return 1
}

FILE_SIZE_STAT_STYLE=""
detect_stat_style() {
  if stat -c %s / >/dev/null 2>&1; then
    FILE_SIZE_STAT_STYLE="gnu"
  elif stat -f %z / >/dev/null 2>&1; then
    FILE_SIZE_STAT_STYLE="bsd"
  else
    echo "ERROR: 当前系统 stat 不支持获取文件大小"
    exit 1
  fi
}

get_file_size() {
  local f="$1"
  local out=""
  if [[ "$FILE_SIZE_STAT_STYLE" == "gnu" ]]; then
    out="$(stat -c %s -- "$f" 2>/dev/null || true)"
  else
    out="$(stat -f %z -- "$f" 2>/dev/null || true)"
  fi
  if [[ "$out" =~ ^[0-9]+$ ]]; then
    printf "%s" "$out"
  fi
}

DU_HAS_DEPTH=0
detect_du_depth_support() {
  if du -k -d 0 -- "$SCAN_PATH" >/dev/null 2>&1; then
    DU_HAS_DEPTH=1
  else
    DU_HAS_DEPTH=0
  fi
}

apply_filters() {
  local in_file="$1"
  local out_file="$2"
  : > "$out_file"
  while IFS=$'\t' read -r p size; do
    [[ -z "$p" || -z "${size:-}" ]] && continue
    if path_allowed "$p"; then
      printf "%s\t%s\n" "$p" "$size" >> "$out_file"
    fi
  done < "$in_file"
}

scan_dir_with_du() {
  local out_file="$1"
  local err_file="$2"
  local raw_file="$3"
  : > "$raw_file"
  : > "$out_file"
  : > "$err_file"

  du -k -d "$DEPTH" -- "$SCAN_PATH" > "$raw_file" 2> "$err_file" || true
  awk '
    NF >= 2 && $1 ~ /^[0-9]+$/ {
      kb = $1
      $1 = ""
      sub(/^[ \t]+/, "", $0)
      if ($0 != "") {
        printf "%s\t%d\n", $0, kb * 1024
      }
    }
  ' "$raw_file" > "$out_file"
}

scan_dir_with_find() {
  local out_file="$1"
  local err_file="$2"
  local list_file="$3"
  : > "$out_file"
  : > "$err_file"
  : > "$list_file"

  {
    printf "%s\n" "$SCAN_PATH"
    find "$SCAN_PATH" -mindepth 1 -maxdepth "$DEPTH" -type d -print
  } > "$list_file" 2> "$err_file" || true

  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    local kb
    kb="$(du -sk -- "$d" 2>>"$err_file" | awk 'NR==1{print $1}')"
    if [[ "$kb" =~ ^[0-9]+$ ]]; then
      printf "%s\t%d\n" "$d" "$((kb * 1024))"
    fi
  done < "$list_file" > "$out_file"
}

scan_file_mode() {
  local out_file="$1"
  local err_file="$2"
  : > "$out_file"
  : > "$err_file"

  if [[ -f "$SCAN_PATH" ]]; then
    local size
    size="$(get_file_size "$SCAN_PATH")"
    if [[ -n "$size" ]]; then
      printf "%s\t%s\n" "$SCAN_PATH" "$size" > "$out_file"
    fi
    return
  fi

  if [[ ! -d "$SCAN_PATH" ]]; then
    echo "ERROR: file 模式下 --path 必须是文件或目录: $SCAN_PATH" >> "$err_file"
    return
  fi

  find "$SCAN_PATH" -type f -print 2> "$err_file" | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local size
    size="$(get_file_size "$f")"
    if [[ -n "$size" ]]; then
      printf "%s\t%s\n" "$f" "$size"
    fi
  done > "$out_file"
}

compute_deltas() {
  local prev_file="$1"
  local curr_file="$2"
  local delta_file="$3"

  awk -F '\t' '
    NR == FNR {
      prev[$1] = $2
      next
    }
    {
      p = $1
      c = $2 + 0
      if (p in prev) {
        d = c - (prev[p] + 0)
      } else {
        d = 0
      }
      if (d > 0) {
        printf "%d\t%s\t%d\n", d, p, c
      }
    }
  ' "$prev_file" "$curr_file" | sort -t $'\t' -k1,1nr | head -n "$TOP_N" > "$delta_file"
}

render_ui() {
  local now="$1"
  local permission_denied="$2"
  local baseline_mode="$3"
  local delta_file="$4"

  screen_clear

  echo "${COLOR_TITLE}FSDeltaMonitor - 磁盘增长实时监测${COLOR_RESET}"
  echo "时间: $now"
  echo "路径: $SCAN_PATH"
  echo "模式: $MODE    深度: $DEPTH    间隔: ${INTERVAL}s    Top: $TOP_N"
  echo "状态文件: $STATE_FILE"

  if [[ "$permission_denied" -gt 0 ]]; then
    echo "${COLOR_WARN}权限不足已跳过: ${permission_denied} 项${COLOR_RESET}"
  fi

  if [[ "$baseline_mode" -eq 1 ]]; then
    echo "${COLOR_MUTED}已建立基线，下一轮开始显示增长（仅 delta > 0）。${COLOR_RESET}"
  fi

  echo
  printf "%-5s %-48s %-12s %-12s %-12s %s\n" "Rank" "Path" "Current" "Delta" "Rate/s" "Bar"
  printf "%-5s %-48s %-12s %-12s %-12s %s\n" "----" "----" "-------" "-----" "------" "---"

  if [[ ! -s "$delta_file" ]]; then
    echo "${COLOR_MUTED}(暂无增长项)${COLOR_RESET}"
    return
  fi

  local max_delta
  max_delta="$(awk -F '\t' 'NR==1{print $1}' "$delta_file")"
  if [[ -z "$max_delta" || "$max_delta" -le 0 ]]; then
    max_delta=1
  fi

  local rank=0
  local bar_w=24
  while IFS=$'\t' read -r delta path curr; do
    rank=$((rank + 1))
    local rate=$((delta / INTERVAL))
    local curr_h delta_h rate_h shown_path filled empty
    curr_h="$(human_size "$curr")"
    delta_h="$(human_size "$delta")"
    rate_h="$(human_size "$rate")"
    shown_path="$(truncate_path "$path" 48)"
    filled=$((delta * bar_w / max_delta))
    if [[ "$filled" -lt 1 ]]; then
      filled=1
    fi
    if [[ "$filled" -gt "$bar_w" ]]; then
      filled="$bar_w"
    fi
    empty=$((bar_w - filled))
    printf "%-5d %-48s %-12s ${COLOR_GOOD}%-12s${COLOR_RESET} %-12s " "$rank" "$shown_path" "$curr_h" "$delta_h" "${rate_h}/s"
    repeat_char "#" "$filled"
    repeat_char "." "$empty"
    printf "\n"
  done < "$delta_file"
}

COUNT_PERMISSION_DENIED=0
scan_once() {
  : > "$RAW_CURR"
  : > "$CURR_FILE"
  : > "$ERR_FILE"

  if [[ "$MODE" == "dir" ]]; then
    if [[ "$DU_HAS_DEPTH" -eq 1 ]]; then
      scan_dir_with_du "$RAW_CURR" "$ERR_FILE" "$TMP_RAW_DU"
      if [[ ! -s "$RAW_CURR" ]]; then
        scan_dir_with_find "$RAW_CURR" "$ERR_FILE" "$TMP_DIR_LIST"
      fi
    else
      scan_dir_with_find "$RAW_CURR" "$ERR_FILE" "$TMP_DIR_LIST"
    fi
  else
    scan_file_mode "$RAW_CURR" "$ERR_FILE"
  fi

  apply_filters "$RAW_CURR" "$CURR_FILE"
  COUNT_PERMISSION_DENIED="$(grep -c 'Permission denied' "$ERR_FILE" 2>/dev/null || true)"
  if [[ ! "$COUNT_PERMISSION_DENIED" =~ ^[0-9]+$ ]]; then
    COUNT_PERMISSION_DENIED=0
  fi
}

cleanup() {
  rm -f -- \
    "$STATE_FILE" \
    "$CURR_FILE" \
    "$RAW_CURR" \
    "$DELTA_FILE" \
    "$ERR_FILE" \
    "$TMP_RAW_DU" \
    "$TMP_DIR_LIST" 2>/dev/null || true
}

main() {
  parse_args "$@"
  validate_args
  resolve_mode
  init_colors
  detect_stat_style
  detect_du_depth_support

  local uid_val key
  uid_val="$(id -u 2>/dev/null || echo "${USER:-unknown}")"
  key="$(printf '%s|%s|%s|%s' "$SCAN_PATH" "$MODE" "$DEPTH" "$TOP_N" | cksum | awk '{print $1}')"

  STATE_FILE="${TMP_ROOT}/fsdelta_${uid_val}_${key}.state"
  CURR_FILE="${STATE_FILE}.curr"
  RAW_CURR="${STATE_FILE}.raw"
  DELTA_FILE="${STATE_FILE}.delta"
  ERR_FILE="${STATE_FILE}.err"
  TMP_RAW_DU="${STATE_FILE}.du.raw"
  TMP_DIR_LIST="${STATE_FILE}.dirs"

  trap cleanup EXIT INT TERM

  local first_round=1
  while true; do
    scan_once

    local now
    now="$(date '+%F %T')"
    if [[ "$first_round" -eq 1 || ! -s "$STATE_FILE" ]]; then
      cp -f -- "$CURR_FILE" "$STATE_FILE"
      : > "$DELTA_FILE"
      render_ui "$now" "$COUNT_PERMISSION_DENIED" 1 "$DELTA_FILE"
      first_round=0
    else
      compute_deltas "$STATE_FILE" "$CURR_FILE" "$DELTA_FILE"
      cp -f -- "$CURR_FILE" "$STATE_FILE"
      render_ui "$now" "$COUNT_PERMISSION_DENIED" 0 "$DELTA_FILE"
    fi

    if [[ "$ONCE" -eq 1 ]]; then
      break
    fi

    local waited=0
    while [[ "$waited" -lt "$INTERVAL" ]]; do
      if read_quit_key; then
        echo
        echo "收到退出指令，结束监测。"
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
  done
}

main "$@"
