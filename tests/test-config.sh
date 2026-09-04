#!/usr/bin/env bash
# Unit tests for per-course config discovery. No network.
#
# The load-order and parsing tests matter, but the one that earns its keep is
# "a config file is not executed": course.env is committed to a repo other
# people can push to, so sourcing it would hand them code execution on the
# instructor's machine.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../gh-rba"
set +e

FAILS=0
check() {  # $1 description, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — expected '$2', got '$3'"
    FAILS=$((FAILS + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Each case runs in its own directory, because load_config reads from $PWD.
in_dir() {  # $1 dirname -> cds into a fresh dir under $TMP
  mkdir -p "$TMP/$1" && cd "$TMP/$1" || exit 1
}

read_org() {  # -> the ORG load_config settles on, or "" if none
  ORG=""
  load_config
  printf '%s' "$ORG"
}

echo "rba_config_value:"
in_dir parse
printf 'ORG="202610-CSCI-350"\n' > course.env
check "double-quoted value"  "202610-CSCI-350" "$(rba_config_value ORG course.env)"
printf "ORG='202610-CSCI-350'\n" > course.env
check "single-quoted value"  "202610-CSCI-350" "$(rba_config_value ORG course.env)"
printf 'ORG=202610-CSCI-350\n' > course.env
check "bare value"           "202610-CSCI-350" "$(rba_config_value ORG course.env)"
printf 'ORG =  202610-CSCI-350   \n' > course.env
check "whitespace tolerated" "202610-CSCI-350" "$(rba_config_value ORG course.env)"
printf '# ORG="commented-out"\nORG="real"\n' > course.env
check "comments skipped"     "real"            "$(rba_config_value ORG course.env)"
printf 'ORG="first"\nORG="second"\n' > course.env
check "first wins"           "first"           "$(rba_config_value ORG course.env)"
printf 'ORGANISATION="no"\n' > course.env
check "no partial key match" ""                "$(rba_config_value ORG course.env)"
check "missing file"         ""                "$(rba_config_value ORG nope.env)"

echo "load_config:"
in_dir none
check "no config leaves ORG empty" "" "$(read_org)"

in_dir current
printf 'ORG="from-course-env"\n' > course.env
check "reads course.env" "from-course-env" "$(read_org)"

in_dir legacy
printf 'ORG="from-legacy"\n' > .rba
check "falls back to .rba" "from-legacy" "$(read_org)"

in_dir both
printf 'ORG="from-course-env"\n' > course.env
printf 'ORG="from-legacy"\n'     > .rba
check "course.env beats .rba" "from-course-env" "$(read_org)"

in_dir extra
cat > course.env <<'EOF'
ORG="202610-CSCI-350"
COURSE="CSCI-350"
ROSTER="roster.txt"
TEMPLATE_act01="act01-lexer-template"
EOF
check "unknown keys ignored, ORG still found" "202610-CSCI-350" "$(read_org)"

echo "config files are DATA, not script:"
in_dir exec
cat > course.env <<'EOF'
ORG="safe"
touch ./PWNED
EOF
read_org > /dev/null
check "a command in the file does not run" "absent" \
      "$([[ -e ./PWNED ]] && echo present || echo absent)"

in_dir subst
printf 'ORG="$(touch ./PWNED2)injected"\n' > course.env
got="$(read_org)"
check "command substitution not evaluated" "absent" \
      "$([[ -e ./PWNED2 ]] && echo present || echo absent)"
check "substitution kept as a literal" '$(touch ./PWNED2)injected' "$got"

cd "$HERE"
if (( FAILS == 0 )); then
  echo "test-config: PASS"
else
  echo "test-config: $FAILS FAILURE(S)"
  exit 1
fi
