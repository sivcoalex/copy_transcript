#!/bin/zsh
# Diktafón – inštalácia jedným príkazom:
#   curl -fsSL https://raw.githubusercontent.com/sivcoalex/copy_transcript/main/install.sh | zsh
set -euo pipefail

REPO="sivcoalex/copy_transcript"
APP_URL="https://github.com/$REPO/releases/latest/download/Diktafon.zip"
HF="https://huggingface.co"
MODELS="$HOME/Library/Application Support/Diktafon/models"

say_step() { print -P "%F{cyan}==>%f $1"; }
fail() { print -P "%F{red}Chyba:%f $1" >&2; exit 1; }

# Requirements: Apple Silicon + macOS 14+
[[ "$(uname -m)" == "arm64" ]] || fail "Diktafón potrebuje Mac s čipom Apple (M1 alebo novší)."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || fail "Diktafón potrebuje macOS 14 (Sonoma) alebo novší."

# Install location: /Applications, or ~/Applications when it isn't writable
DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say_step "Sťahujem Diktafón…"
curl -fL --progress-bar -o "$TMP/Diktafon.zip" "$APP_URL" || fail "Nepodarilo sa stiahnuť appku."
ditto -x -k "$TMP/Diktafon.zip" "$TMP"
[[ -d "$TMP/Diktafon.app" ]] || fail "Stiahnutý archív neobsahuje Diktafon.app."

pkill -x Diktafon 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Diktafon.app"
mv "$TMP/Diktafon.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Diktafon.app" 2>/dev/null || true
say_step "Appka je v $DEST/Diktafon.app"

download_model() { # <file> <hugging face repo> <description>
  local file="$1" repo="$2" desc="$3"
  if [[ -f "$MODELS/$file" ]]; then
    say_step "$desc už je stiahnutý."
    return
  fi
  say_step "Sťahujem $desc (iba raz)…"
  curl -fL --progress-bar -o "$MODELS/$file.part" "$HF/$repo/resolve/main/$file" || fail "Nepodarilo sa stiahnuť $file."
  mv "$MODELS/$file.part" "$MODELS/$file"
}

mkdir -p "$MODELS"
download_model "ggml-silero-v6.2.0.bin" "ggml-org/whisper-vad" "filter reči (1 MB)"
download_model "ggml-large-v3-turbo-q8_0.bin" "ggerganov/whisper.cpp" "rýchly model (830 MB)"
download_model "ggml-large-v3-q5_0.bin" "ggerganov/whisper.cpp" "presnejší model (1,1 GB)"

say_step "Spúšťam Diktafón…"
open "$DEST/Diktafon.app"

print
print -P "%F{green}Hotovo!%f Ikonka mikrofónu je vpravo hore v lište."
print "  • Pri prvom spustení povoľ prístup k mikrofónu."
print "  • Diktovanie zapneš a vypneš skratkou ⌃⌥ medzerník (Control + Option + medzerník)."
print "  • Prepísaný text sa skopíruje do schránky – vlož ho cez ⌘V."
