#!/usr/bin/env bash
# rba_template_for: --template > TEMPLATE_<name> in course.env > convention.
#
# The override case is the one that earns its keep. act01 and hw01 predate the
# <name>-template convention, and their student repos record the old names in
# template_repository.full_name -- which `assignment patch` matches on. So the
# repos cannot be renamed to fit, and the tool has to read the override that
# course.env has been carrying all along.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../gh-rba"
set +e

FAILS=0
check() {  # $1 desc, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"
  else echo "  FAIL $1 — expected '$2', got '$3'"; FAILS=$((FAILS+1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

echo "rba_template_for:"

check "no config -> the <name>-template convention" \
      "myorg/hw02-template" "$(rba_template_for hw02 myorg)"

cat > course.env <<'CFG'
ORG="myorg"
TEMPLATE_hw01="hw01-lexer-template"
TEMPLATE_act01="act01-lexer-template"
TEMPLATE_shared="otherorg/shared-template"
CFG

check "an override is used"                 "myorg/hw01-lexer-template" "$(rba_template_for hw01 myorg)"
check "a second override is independent"    "myorg/act01-lexer-template" "$(rba_template_for act01 myorg)"
check "a name with no override still falls through" \
      "myorg/hw02-template" "$(rba_template_for hw02 myorg)"
check "a value containing / keeps its own org" \
      "otherorg/shared-template" "$(rba_template_for shared myorg)"
check "the org argument is what gets prefixed" \
      "another/hw01-lexer-template" "$(rba_template_for hw01 another)"

# Assignment names have dashes; config keys are conventionally underscored.
# Every entry written by hand so far uses the underscore form, and the lookup
# only ever tried the dashed one -- so TEMPLATE_icp_1 sat there being ignored.
cat >> course.env <<'CFG'
TEMPLATE_icp_3="icp-3-template-custom"
TEMPLATE_lab-4="lab-4-template-custom"
CFG

check "an underscored key matches a dashed assignment name" \
      "myorg/icp-3-template-custom" "$(rba_template_for icp-3 myorg)"
check "a dashed key still matches, unchanged" \
      "myorg/lab-4-template-custom" "$(rba_template_for lab-4 myorg)"
check "a name with no dash is unaffected" \
      "myorg/hw02-template" "$(rba_template_for hw02 myorg)"

printf '# TEMPLATE_commented="nope"\n' >> course.env
check "a commented-out override is ignored" \
      "myorg/commented-template" "$(rba_template_for commented myorg)"

printf 'TEMPLATE_blank=""\n' >> course.env
check "an empty override falls through rather than yielding 'myorg/'" \
      "myorg/blank-template" "$(rba_template_for blank myorg)"

# legacy .rba is still honoured, as load_config does
rm -f course.env
printf 'TEMPLATE_legacy="legacy-tpl"\n' > .rba
check "the legacy .rba file is read too" \
      "myorg/legacy-tpl" "$(rba_template_for legacy myorg)"

if (( FAILS == 0 )); then echo "test-template: PASS"
else echo "test-template: $FAILS FAILURE(S)"; exit 1; fi
