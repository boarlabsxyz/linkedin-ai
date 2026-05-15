#!/usr/bin/env bash
# Download a YouTube video's auto-captions and emit a clean timestamped transcript.
#
# Usage:
#     download-youtube-transcript.sh <youtube-url> [lang]
#
# `lang` is the preferred caption language. Defaults to `en`. If unavailable,
# the script silently falls back through: [requested, en, ru, uk, then the first
# auto-caption language YouTube actually offers] — no red errors for the normal
# "video is in another language" case.
#
# Cache: writes raw VTT, cleaned transcript, and a small meta file to
# <project>/tmp/transcripts/. Repeated runs reuse the cache and never touch the
# network — important when YouTube rate-limits the IP.
#
# Output (stdout, parseable, one KEY=VALUE per line):
#     TRANSCRIPT_PATH=...
#     TITLE=...
#     CHANNEL=...
#     UPLOAD_DATE=...
#     LANG=...
#
# Exit codes:
#     0  — success (cached or freshly downloaded)
#     1  — yt-dlp not installed
#     2  — no auto-captions available in any language we tried
#     3  — yt-dlp couldn't reach YouTube (rate limit / network) and nothing cached
#     64 — bad arguments

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <youtube-url> [lang]" >&2
    exit 64
fi

URL="$1"
PREFERRED_LANG="${2:-en}"

# --- yt-dlp install check -------------------------------------------------
if ! command -v yt-dlp >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: yt-dlp is not installed (or not on PATH).

This script requires yt-dlp to extract YouTube transcripts. The skill will not
fall back to Playwright or any other method — please install yt-dlp first.

How to fix:

  1. Install via Homebrew (recommended on macOS):
         brew install yt-dlp

  2. Or via pipx:
         pipx install yt-dlp

  3. Or via pip:
         pip3 install --user yt-dlp

After install, verify with:
    yt-dlp --version
EOF
    exit 1
fi

# --- Resolve project root and output dir ----------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
OUT_DIR="$PROJECT_ROOT/tmp/transcripts"
mkdir -p "$OUT_DIR"

# --- Resolve VIDEO_ID without a network call when the URL is well-formed --
extract_id_from_url() {
    local url="$1"
    if [[ "$url" =~ [?\&]v=([A-Za-z0-9_-]{11}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$url" =~ youtu\.be/([A-Za-z0-9_-]{11}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$url" =~ /(embed|v|shorts|live)/([A-Za-z0-9_-]{11}) ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"; return 0
    fi
    return 1
}

VIDEO_ID="$(extract_id_from_url "$URL" || true)"
if [[ -z "$VIDEO_ID" ]]; then
    VIDEO_ID="$(yt-dlp --skip-download --print "%(id)s" "$URL" 2>/dev/null | tail -n1 || true)"
fi
if [[ -z "${VIDEO_ID:-}" ]]; then
    echo "ERROR: could not resolve video ID for $URL" >&2
    exit 3
fi

META_PATH="$OUT_DIR/yt-${VIDEO_ID}.meta.tsv"

# --- 1. Cache hit on requested language? ----------------------------------
SELECTED_CLEAN=""
SELECTED_LANG=""
if [[ -s "$OUT_DIR/yt-${VIDEO_ID}.${PREFERRED_LANG}.clean.txt" ]]; then
    SELECTED_CLEAN="$OUT_DIR/yt-${VIDEO_ID}.${PREFERRED_LANG}.clean.txt"
    SELECTED_LANG="$PREFERRED_LANG"
fi

# --- 2. Build fallback ladder of languages to try -------------------------
# Order: requested, then en/ru/uk (deduped). After downloading attempts, we
# also tack on whatever yt-dlp tells us is actually available.
declare -a LANG_CHAIN=()
add_lang() {
    local l="$1"
    [[ -z "$l" ]] && return
    for existing in "${LANG_CHAIN[@]:-}"; do
        [[ "$existing" == "$l" ]] && return
    done
    LANG_CHAIN+=("$l")
}
add_lang "$PREFERRED_LANG"
add_lang "en"
add_lang "ru"
add_lang "uk"

# --- 3. Cache hit on any other language? ----------------------------------
if [[ -z "$SELECTED_CLEAN" ]]; then
    for lang in "${LANG_CHAIN[@]}"; do
        candidate="$OUT_DIR/yt-${VIDEO_ID}.${lang}.clean.txt"
        if [[ -s "$candidate" ]]; then
            SELECTED_CLEAN="$candidate"
            SELECTED_LANG="$lang"
            if [[ "$lang" != "$PREFERRED_LANG" ]]; then
                echo "NOTICE: using cached '${lang}' transcript ('${PREFERRED_LANG}' not cached)." >&2
            fi
            break
        fi
    done
fi
if [[ -z "$SELECTED_CLEAN" ]]; then
    # Glob for any other cached language we don't know about
    for f in "$OUT_DIR"/yt-${VIDEO_ID}.*.clean.txt; do
        [[ -e "$f" ]] || continue
        base="${f##*/}"; base="${base#yt-${VIDEO_ID}.}"; base="${base%.clean.txt}"
        SELECTED_CLEAN="$f"
        SELECTED_LANG="$base"
        echo "NOTICE: using cached '${base}' transcript (no '${PREFERRED_LANG}' available)." >&2
        break
    done
fi

# --- 4. If still nothing, attempt downloads through the language ladder ---
try_download() {
    local lang="$1"
    local vtt="$OUT_DIR/yt-${VIDEO_ID}.${lang}.vtt"
    local clean="$OUT_DIR/yt-${VIDEO_ID}.${lang}.clean.txt"
    local errfile="${TMPDIR:-/tmp}/yt-dlp-${VIDEO_ID}-${lang}.err"

    if yt-dlp \
            --skip-download \
            --write-auto-sub \
            --sub-lang "$lang" \
            --sub-format vtt \
            -o "$OUT_DIR/yt-${VIDEO_ID}.%(ext)s" \
            "$URL" >"$errfile" 2>&1; then
        rm -f "$errfile"
        if [[ -f "$vtt" ]]; then
            python3 "$SCRIPT_DIR/clean-vtt.py" "$vtt" "$clean"
            SELECTED_CLEAN="$clean"
            SELECTED_LANG="$lang"
            return 0
        fi
        # yt-dlp succeeded but didn't produce a file → captions don't exist in this lang
        return 2
    fi

    # yt-dlp failed — classify
    if grep -qiE '429|too many requests' "$errfile"; then
        rm -f "$errfile"
        return 3   # rate-limited; no point trying more languages immediately
    fi
    rm -f "$errfile"
    return 2
}

if [[ -z "$SELECTED_CLEAN" ]]; then
    # First, ask yt-dlp what's actually available, so we don't burn requests on
    # languages that don't exist.
    AVAIL=""
    if AVAIL_RAW="$(yt-dlp --skip-download --list-subs "$URL" 2>/dev/null)"; then
        AVAIL="$(printf '%s\n' "$AVAIL_RAW" | awk '
            /Available (subtitles|automatic captions)/ { in_block=1; getline; next }
            /^\[/ { in_block=0 }
            in_block && /^[a-z]/ && NF>=2 { print $1 }
        ' | sort -u)"
        # Append any newly-discovered languages to the ladder
        while IFS= read -r lang; do
            [[ -n "$lang" ]] && add_lang "$lang"
        done <<<"$AVAIL"
    fi

    DL_RC=2
    for lang in "${LANG_CHAIN[@]}"; do
        # Skip if list-subs was successful and lang isn't in it
        if [[ -n "$AVAIL" ]] && ! grep -qx -- "$lang" <<<"$AVAIL"; then
            continue
        fi
        try_download "$lang" && { DL_RC=0; break; } || DL_RC=$?
        if [[ "$DL_RC" -eq 3 ]]; then
            echo "ERROR: YouTube rate-limited this request (HTTP 429) and no transcript is cached for video $VIDEO_ID. Try again later." >&2
            exit 3
        fi
        if [[ "$lang" != "$PREFERRED_LANG" ]]; then
            echo "NOTICE: '$PREFERRED_LANG' not available; trying '$lang' next." >&2 || true
        fi
    done

    if [[ "$DL_RC" -ne 0 || -z "$SELECTED_CLEAN" ]]; then
        echo "ERROR: no auto-captions available for $URL in any of: ${LANG_CHAIN[*]}." >&2
        exit 2
    fi

    if [[ "$SELECTED_LANG" != "$PREFERRED_LANG" ]]; then
        echo "NOTICE: downloaded '${SELECTED_LANG}' captions ('${PREFERRED_LANG}' not offered for this video)." >&2
    fi
fi

# --- 5. Metadata: cache → live fetch → graceful fallback ------------------
TITLE=""; CHANNEL=""; UPLOAD_DATE=""
if [[ -s "$META_PATH" ]]; then
    IFS=$'\t' read -r TITLE CHANNEL UPLOAD_DATE < "$META_PATH" || true
fi
if [[ -z "$TITLE" ]]; then
    if META="$(yt-dlp --skip-download \
            --print "%(title)s" \
            --print "%(channel)s" \
            --print "%(upload_date)s" \
            "$URL" 2>/dev/null)"; then
        TITLE="$(printf '%s\n' "$META" | sed -n '1p')"
        CHANNEL="$(printf '%s\n' "$META" | sed -n '2p')"
        UPLOAD_DATE="$(printf '%s\n' "$META" | sed -n '3p')"
        printf '%s\t%s\t%s\n' "$TITLE" "$CHANNEL" "$UPLOAD_DATE" > "$META_PATH"
    else
        TITLE="(metadata unavailable)"
        CHANNEL="unknown"
        UPLOAD_DATE="unknown"
    fi
fi

cat <<EOF
TRANSCRIPT_PATH=$SELECTED_CLEAN
TITLE=$TITLE
CHANNEL=$CHANNEL
UPLOAD_DATE=$UPLOAD_DATE
LANG=$SELECTED_LANG
EOF
