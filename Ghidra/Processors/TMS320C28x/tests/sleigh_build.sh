#!/usr/bin/env bash
# =============================================================================
# sleigh_build.sh -- reproducible TMS320C28x SLEIGH build + verify harness
#
# Compiles the C28x language spec and diffs the result against a baseline .sla,
# so every spec change can be proven to compile and its blast radius measured
# BEFORE it is dropped into a Ghidra install.
#
# Established 2026-07-30. Baseline reproduced byte-identically:
#   md5 00d602cb48f9d1ad7f98d133c88964fc  (36150 bytes, 281484 uncompressed)
#
# ---- JDK NOTE (the part that is easy to lose) -------------------------------
# Ghidra 12.x class files are version 65 => JDK 21+. This sandbox ships JDK 11,
# has no root (apt is unavailable), and BOTH of the obvious download paths are
# blocked by the egress proxy:
#     api.adoptium.net                       -> 403 at CONNECT
#     release-assets.githubusercontent.com   -> 403 at CONNECT
#       (github.com itself answers 200 and issues the 302, but the asset host
#        it redirects to is the one that is blocked, so release downloads fail)
# PyPI is reachable, and the `jdk4py` wheel bundles a complete Temurin runtime
# whose version number tracks the Java version. So:
#     pip download "jdk4py==21.*" -d /tmp/j21 --no-deps
#     unzip -q /tmp/j21/*.whl -d /tmp/jdk21
#     chmod +x /tmp/jdk21/jdk4py/java-runtime/bin/*
# gives Temurin 21.0.8 with the full java.se module set, which is enough for
# SleighCompile. Pin to 21.* rather than taking latest -- latest is Java 25,
# which also works but is not what Ghidra targets.
#
# ---- HARMLESS ERROR (do not chase it) ---------------------------------------
# Ghidra's logger tries to resolve the machine hostname and throws
#     java.net.UnknownHostException: <hostname>: Temporary failure in name resolution
# with ~17 stack frames. This happens AFTER the .sla is written and does not
# affect output. A build that prints this stack trace and still produces a .sla
# SUCCEEDED. Judge success by "is there a .sla and did it change", never by
# whether the log looks clean.
#
# ---- WHAT A CLEAN BUILD LOOKS LIKE ------------------------------------------
#   22 NOP constructors found
#   20 unnecessary extensions/truncations were converted to copies
#   5 operations wrote to temporaries that were not read
# Any line containing ERROR means NO .sla was written -- read the FIRST error,
# later ones cascade. See docs/SLEIGH-IDIOMS.md in the module.
# =============================================================================
set -uo pipefail

JAVA="${JAVA:-/tmp/jdk21/jdk4py/java-runtime/bin/java}"
GHIDRA="${GHIDRA:-/sessions/sweet-wonderful-knuth/mnt/Ghidra}"
SRC="${SRC:-$GHIDRA/Ghidra/Processors/TMS320C28x/data/languages}"
WORK="${WORK:-/tmp/sleigh_work}"
BASELINE="${BASELINE:-$SRC/tms320c28x.sla}"

die() { echo "FATAL: $*" >&2; exit 1; }

# --- 0. bootstrap the JDK if it is not already unpacked ----------------------
if [ ! -x "$JAVA" ]; then
  echo "== JDK 21 not found at $JAVA, fetching from PyPI =="
  pip download "jdk4py==21.*" -d /tmp/j21 --no-deps >/dev/null 2>&1 \
    || die "pip download jdk4py failed (is PyPI reachable?)"
  rm -rf /tmp/jdk21 && mkdir -p /tmp/jdk21
  unzip -q /tmp/j21/*.whl -d /tmp/jdk21 || die "unzip of jdk4py wheel failed"
  chmod +x /tmp/jdk21/jdk4py/java-runtime/bin/* 2>/dev/null
  [ -x "$JAVA" ] || die "JDK still not executable at $JAVA"
fi
echo "== JDK: $("$JAVA" -version 2>&1 | head -1)"

# --- 1. classpath ------------------------------------------------------------
CP=$(find "$GHIDRA/Ghidra/Framework" -name '*.jar' 2>/dev/null | tr '\n' ':')
[ -n "$CP" ] || die "no jars found under $GHIDRA/Ghidra/Framework"

# --- 2. stage sources (excluding the .bak/_bak sweep archive) ----------------
rm -rf "$WORK" && mkdir -p "$WORK"
cp "$SRC"/*.slaspec "$SRC"/*.sinc "$WORK/" 2>/dev/null
( cd "$WORK" && rm -f *.bak *_bak *.pre_* 2>/dev/null )
echo "== staged $(ls "$WORK" | wc -l) spec files in $WORK"

# --- 3. compile --------------------------------------------------------------
OUT="$WORK/tms320c28x.sla"
LOG="$WORK/build.log"
"$JAVA" -cp "$CP" ghidra.pcodeCPort.slgh_compile.SleighCompile \
        "$WORK/tms320c28x.slaspec" "$OUT" >"$LOG" 2>&1

# Filter the hostname-resolution noise described in the header.
grep -v -E '^\s+at |^Caused by|UnknownHostException|^\s+\.\.\. [0-9]+ more' "$LOG" \
  | grep -v '^\s*$' | sed 's/^/   /'

if grep -q "ERROR" "$LOG"; then
  echo
  echo "!! ERROR in build -- first occurrence:"
  grep -m3 "ERROR" "$LOG" | sed 's/^/   /'
  die "compile failed, no .sla written"
fi
[ -s "$OUT" ] || die "no .sla produced (see $LOG)"

# --- 4. compare against baseline --------------------------------------------
echo
echo "== result"
printf "   new      %8s bytes  %s\n" "$(stat -c%s "$OUT")" "$(md5sum "$OUT" | cut -c1-32)"
if [ -f "$BASELINE" ]; then
  printf "   baseline %8s bytes  %s\n" "$(stat -c%s "$BASELINE")" "$(md5sum "$BASELINE" | cut -c1-32)"
  python3 - "$OUT" "$BASELINE" <<'PY'
import sys, zlib, difflib
def unpack(p):
    d = open(p, 'rb').read()
    assert d[:3] == b'sla', f"{p}: not a packed .sla"
    return zlib.decompress(d[4:]).decode('utf8', 'replace')
new, base = unpack(sys.argv[1]), unpack(sys.argv[2])
print(f"   uncompressed: new {len(new)}  baseline {len(base)}")
if new == base:
    print("   IDENTICAL -- the spec change had NO effect on the compiled language.")
    print("   If you expected a change, the edit did not take (check you edited the")
    print("   file the .slaspec actually includes, and that it is not a comment).")
else:
    a, b = base.splitlines(), new.splitlines()
    delta = sum(1 for l in difflib.unified_diff(a, b, n=0) if l[:1] in '+-' and l[:3] not in ('---','+++'))
    print(f"   CHANGED -- {delta} differing lines in the uncompressed spec")
PY
else
  echo "   (no baseline at $BASELINE to compare against)"
fi

cat <<'EOF'

== to install
   cp <the .sla above> <GHIDRA>/Ghidra/Processors/TMS320C28x/data/languages/
   then RESTART Ghidra -- a running instance keeps the old language in memory,
   and RE-IMPORT the target: an already-imported program is bound to the
   language it was imported under, so re-analysis alone will NOT pick up new
   or changed constructors. This is the single most common way a correct
   SLEIGH fix appears to have done nothing.
EOF
