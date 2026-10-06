#!/usr/bin/env bash
# Verify the machine is in a measurable state, and record what it looked like.
# Everything printed here belongs in the report's "Experimental Environment"
# section.  Output is also saved to out/env.txt.
source "$(dirname "$0")/lib.sh"
# the build uses a self-contained JDK if the system has only a JRE
[ -f "$ROOT/.tools/jdk.env" ] && . "$ROOT/.tools/jdk.env"

REPORT="$OUT_DIR/env.txt"
: > "$REPORT"
say() { echo "$@" | tee -a "$REPORT"; }

say "=== generated $(date -Is) ==="
say ""

say "## CPU"
say "$(lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Core|Socket|MHz|BogoMIPS)' | sed 's/^/    /')"
say ""
say "topology (physical core -> SMT siblings):"
for c in /sys/devices/system/cpu/cpu*/topology/thread_siblings_list; do
  own="$(basename "$(dirname "$(dirname "$c")")")"
  case "$own" in cpu[0-9]|cpu[0-9][0-9]) ;; *) continue ;; esac
  sib="$(cat "$c")"
  [ "$own" = "cpu${sib%%,*}" ] || continue
  say "    $own -> $sib"
done
say ""
say "server cpuset : $SERVER_CPUS"
say "client cpuset : $CLIENT_CPUS"
say ""

say "## Frequency governor  (must be 'performance' for reproducible numbers)"
GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'n/a')"
say "    current = $GOV"
if [ "$GOV" != "performance" ]; then
  say "    -> FIX:  echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
fi
say "    turbo/boost state = $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a) (1 = turbo off)"
say ""

say "## Memory"
say "$(free -h | sed 's/^/    /')"
say ""

say "## Storage"
say "$(df -hT "$HOST_DATA_ROOT" 2>/dev/null | sed 's/^/    /' || echo '    (HOST_DATA_ROOT does not exist yet)')"
say "    rotational:"
for d in /sys/block/nvme*/queue/rotational /sys/block/sd*/queue/rotational; do
  [ -e "$d" ] || continue
  say "      $d = $(cat "$d")"
done
say "    mount options for $HOST_DATA_ROOT: $(findmnt -no FSTYPE,OPTIONS --target "$HOST_DATA_ROOT" 2>/dev/null || echo n/a)"
say ""

say "## Software"
say "    kernel  : $(uname -r)   ($( . /etc/os-release; echo "$PRETTY_NAME"))"
say "    java    : $(java -version 2>&1 | head -1)"
say "    javac   : $(javac -version 2>&1 | head -1)"
say "    docker  : $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unreachable')"
say "    python  : $(python3 -V 2>&1)"
say ""

say "## Containers"
for c in "$PG_CTR" "$OG_CTR"; do
  if ctr_running "$c"; then
    say "    $c: running  image=$(docker inspect -f '{{.Config.Image}}' "$c")"
    say "      cpuset=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$c")  mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$c")"
  else
    say "    $c: not running"
  fi
done
say ""

say "## JDBC drivers"
for j in "$ROOT"/benchmark/lib/*.jar; do
  [ -e "$j" ] && say "    $(basename "$j")"
done
[ -n "$(ls -A "$ROOT/benchmark/lib" 2>/dev/null | grep -c jar || true)" ] || say "    (none -- run benchmark/build.sh which downloads them)"
say ""

say "## Checklist"
fail=0
chk() { if eval "$2"; then say "    [ok]   $1"; else say "    [TODO] $1"; fail=1; fi; }
chk "governor is performance"          "[ '$GOV' = performance ]"
chk "HOST_DATA_ROOT exists"            "[ -d '$HOST_DATA_ROOT' ]"
chk "javac available"                  "command -v javac >/dev/null"
chk "docker reachable"                 "docker version --format '{{.Server.Version}}' >/dev/null 2>&1"
chk "at least one JDBC jar in lib/"    "ls '$ROOT/benchmark/lib/'*.jar >/dev/null 2>&1"
chk "free RAM >= 12 GiB"               "[ \"\$(free -g | awk '/^Mem:/{print \$2}')\" -ge 12 ]"
chk "free disk on data root >= 60 GiB" "df -BG --output=avail '$HOST_DATA_ROOT' 2>/dev/null | tail -1 | tr -dc 0-9 | awk '{exit !(\$1>=60)}'"

echo
echo "environment report -> $REPORT"
[ "$fail" = 0 ] && echo "all checks passed" || echo "some checks need attention (see [TODO] above)"
