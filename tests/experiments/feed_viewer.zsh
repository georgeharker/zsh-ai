#!/usr/bin/env zsh
# tests/experiments/feed_viewer.zsh — drip a markdown file into a log
# file at adjustable cadence, optionally touching a done-flag at end.
#
# Lets bin/zsh-ai-view be exercised against realistic streamed input
# without firing the LLM — useful for tuning render perf, debounce,
# done-flag handling, scroll/follow UX. Pairs naturally with the
# viewer:
#
#   # terminal A — start the viewer following an empty log:
#   ./bin/zsh-ai-view --file /tmp/v.log --done-file /tmp/v.done --follow
#
#   # terminal B — drip a sample file in:
#   zsh tests/experiments/feed_viewer.zsh sample.md /tmp/v.log /tmp/v.done \
#       --delay 0.15
#
# Or one-terminal (background the feeder, foreground the viewer):
#
#   log=$(mktemp); done="${log}.done"
#   zsh tests/experiments/feed_viewer.zsh sample.md "$log" "$done" --delay 0.15 &!
#   ./bin/zsh-ai-view --file "$log" --done-file "$done" --follow
#   rm -f "$log" "$done"
#
# Args (positional):
#   source     markdown file to read
#   target     log file to write to (truncated at start)
#   done-flag  optional path to touch when feeding finishes
#
# Flags:
#   --delay  S   sleep between chunks (default 0.1). Accepts any value
#                `sleep` understands: 0.1, 100ms, 1s, 2.
#   --chunk  N   characters per chunk (default 0 = whole-line mode).
#                Use a small N (e.g. 8) to simulate token-by-token streaming.

emulate -L zsh
setopt errexit nounset pipefail

usage() {
    cat <<EOF
usage: $0 SOURCE TARGET [DONE-FLAG] [--delay S] [--chunk N]

Drip SOURCE into TARGET at delay S between chunks. Touch DONE-FLAG at end.
See script header for examples.
EOF
}

source_file=""
target_file=""
done_flag=""
delay=0.1
chunk_size=0

while (( $# > 0 )); do
    case "$1" in
        --delay)  delay="$2";       shift 2 ;;
        --chunk)  chunk_size="$2";  shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) print -ru2 -- "unknown flag: $1"; usage; exit 2 ;;
        *)
            if   [[ -z "$source_file" ]]; then source_file="$1"
            elif [[ -z "$target_file" ]]; then target_file="$1"
            elif [[ -z "$done_flag"   ]]; then done_flag="$1"
            else
                print -ru2 -- "too many positional args"; usage; exit 2
            fi
            shift
            ;;
    esac
done

[[ -n "$source_file" && -n "$target_file" ]] || { usage; exit 2; }
[[ -r "$source_file" ]] || { print -ru2 -- "cannot read $source_file"; exit 1; }

# Truncate target + clear done-flag so reruns are predictable.
: > "$target_file"
[[ -n "$done_flag" ]] && rm -f "$done_flag"

print -ru2 -- "feeding $source_file → $target_file (delay=$delay, chunk=$chunk_size)…"

if (( chunk_size > 0 )); then
    # Character-chunked: simulate token-by-token streaming.
    content="$(<$source_file)"
    n=${#content}
    pos=1
    while (( pos <= n )); do
        end=$(( pos + chunk_size - 1 ))
        (( end > n )) && end=$n
        print -rn -- "${content[$pos,$end]}" >> "$target_file"
        pos=$(( end + 1 ))
        sleep "$delay"
    done
else
    # Line-mode (default): one line per chunk.
    while IFS= read -r line || [[ -n "$line" ]]; do
        print -r -- "$line" >> "$target_file"
        sleep "$delay"
    done < "$source_file"
fi

if [[ -n "$done_flag" ]]; then
    touch "$done_flag"
    print -ru2 -- "done flag touched: $done_flag"
fi
