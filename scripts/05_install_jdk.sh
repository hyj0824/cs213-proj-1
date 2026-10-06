#!/usr/bin/env bash
# This machine had only a JRE (no javac) and sudo requires a password, so the
# build uses a self-contained JDK under .tools/ instead of touching the system.
#
# Preferred path: `apt-get download` + `dpkg -x`, which needs no root and pulls
# from the configured Ubuntu mirror (measured at ~9 MB/s here, versus ~30 KB/s
# from api.adoptium.net).  Falls back to the Adoptium tarball.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
JDK="$TOOLS/jdk17"
ENV="$TOOLS/jdk.env"
log() { printf '[jdk] %s\n' "$*"; }

write_env() { # java-home
  printf 'export JAVA_HOME="%s"\nexport PATH="%s/bin:$PATH"\n' "$1" "$1" > "$ENV"
}

if command -v javac >/dev/null 2>&1; then
  JH="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  log "javac already on PATH: $(javac -version 2>&1)"
  write_env "$JH"
  exit 0
fi

if [ -x "$JDK/bin/javac" ]; then
  log "reusing $JDK"
  write_env "$JDK"
  exit 0
fi

mkdir -p "$TOOLS" "$JDK"

if apt-get download openjdk-17-jdk-headless >/dev/null 2>&1 || \
   (cd "$TOOLS" && apt-get download openjdk-17-jdk-headless openjdk-17-jre-headless >/dev/null 2>&1); then
  cd "$TOOLS"
  for deb in openjdk-17-jdk-headless_*.deb openjdk-17-jre-headless_*.deb; do
    [ -e "$deb" ] || continue
    log "extracting $deb"
    dpkg -x "$deb" "$JDK"
    rm -f "$deb"
  done
  REAL="$(find "$JDK" -maxdepth 5 -name javac -type f -path '*bin*' | head -1)"
  if [ -n "$REAL" ]; then
    JH="$(cd "$(dirname "$REAL")/.." && pwd)"
    ln -sfn "$JH" "$TOOLS/jdk17-link"
    write_env "$JH"
    log "installed: $("$REAL" -version 2>&1)  (JAVA_HOME=$JH)"
    exit 0
  fi
  warn="apt route produced no javac; falling back to Adoptium"
  log "$warn"
fi

URL="https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux"
log "downloading a JDK 17 tarball (try the Tsinghua mirror first) ..."
VER="$(curl -s --max-time 20 "$MIRROR/" | grep -o 'OpenJDK17U-jdk_x64_linux_hotspot_[0-9._]*\.tar\.gz' | sort -u | tail -1 || true)"
if [ -n "$VER" ]; then
  curl -fL --retry 2 -o "$TOOLS/jdk17.tar.gz" "$MIRROR/$VER"
else
  curl -fL --retry 3 -o "$TOOLS/jdk17.tar.gz" "$URL"
fi
tar -xzf "$TOOLS/jdk17.tar.gz" -C "$JDK" --strip-components=1
rm -f "$TOOLS/jdk17.tar.gz"
# the extracted tarball root already contains bin/
JH="$(cd "$JDK" && pwd)"
if [ ! -x "$JDK/bin/javac" ]; then
  JH="$(dirname "$(dirname "$(find "$JDK" -name javac -type f | head -1)")")"
fi
write_env "$JH"
log "installed: $("$JH/bin/javac" -version 2>&1)"
