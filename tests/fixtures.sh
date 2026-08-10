#!/usr/bin/env bash
# Builds a template repo plus a "template-instantiated" student repo that
# reproduces the real GitHub topology: the student repo's root commit is a
# squashed snapshot of the template and shares no SHAs with it.
#
# Student remotes are BARE — git refuses pushes to a checked-out branch.

fixture_new() {  # $1 dir
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d"
  git init -q "$d/tpl"
  git -C "$d/tpl" symbolic-ref HEAD refs/heads/main
  git -C "$d/tpl" config user.email instructor@example.edu
  git -C "$d/tpl" config user.name  "Instructor"
}

fixture_tpl_file() {  # $1 dir, $2 path, $3 content
  mkdir -p "$(dirname "$1/tpl/$2")"
  printf '%s' "$3" > "$1/tpl/$2"
}

fixture_tpl_commit() {  # $1 dir, $2 message
  git -C "$1/tpl" add -A
  git -C "$1/tpl" commit -qm "$2"
}

# Snapshot the template into a fresh bare student repo, exactly as GitHub's
# "create from template" does: one squashed root commit named "Initial commit".
fixture_distribute() {  # $1 dir
  local d="$1"
  git init -q --bare "$d/stu.git"
  git clone -q "$d/stu.git" "$d/stuwork" 2>/dev/null
  git -C "$d/stuwork" symbolic-ref HEAD refs/heads/main
  git -C "$d/stuwork" config user.email student@example.edu
  git -C "$d/stuwork" config user.name  "Student"
  ( cd "$d/tpl" && git archive HEAD ) | tar -x -C "$d/stuwork"
  git -C "$d/stuwork" add -A
  git -C "$d/stuwork" commit -qm "Initial commit"
  git -C "$d/stuwork" push -q origin HEAD:refs/heads/main
}

fixture_stu_file() {  # $1 dir, $2 path, $3 content
  mkdir -p "$(dirname "$1/stuwork/$2")"
  printf '%s' "$3" > "$1/stuwork/$2"
}

fixture_stu_commit() {  # $1 dir, $2 message
  git -C "$1/stuwork" add -A
  git -C "$1/stuwork" commit -qm "$2"
  git -C "$1/stuwork" push -q origin HEAD:refs/heads/main
}

# Fresh scratch bare repo with the template already fetched, mirroring what
# cmd_assignment_patch sets up once per invocation. Echoes its path.
fixture_scratch() {  # $1 dir
  local d="$1"
  rm -rf "$d/scratch"
  git init -q --bare "$d/scratch"
  git -C "$d/scratch" fetch -q --no-tags "$d/tpl" '+refs/heads/main:refs/rba/template'
  echo "$d/scratch"
}

# Snapshot the template into a fresh bare student repo as ONE root commit that
# also contains extra student-authored files — i.e. what a student's repo looks
# like after `git rebase -i --root` or `checkout --orphan` squashes everything.
# Exactly one root, but its tree is NOT a template tree.
fixture_distribute_squashed() {  # $1 dir, $2 extra file, $3 extra content
  local d="$1"
  git init -q --bare "$d/stu.git"
  git clone -q "$d/stu.git" "$d/stuwork" 2>/dev/null
  git -C "$d/stuwork" symbolic-ref HEAD refs/heads/main
  git -C "$d/stuwork" config user.email student@example.edu
  git -C "$d/stuwork" config user.name  "Student"
  ( cd "$d/tpl" && git archive HEAD ) | tar -x -C "$d/stuwork"
  printf '%s' "$3" > "$d/stuwork/$2"
  git -C "$d/stuwork" add -A
  git -C "$d/stuwork" commit -qm "squashed history"
  git -C "$d/stuwork" push -q origin HEAD:refs/heads/main
}

# The tree-OID set of the template's history, as cmd_assignment_patch computes
# it once per invocation and passes to rba_patch_repo.
fixture_tpl_trees() {  # $1 scratch dir
  git -C "$1" log --format=%T refs/rba/template
}

# Read a file's content from the student's bare remote (post-push truth).
fixture_stu_show() {  # $1 dir, $2 path
  git -C "$1/stu.git" cat-file blob "main:$2"
}

# Count commits on the student's bare remote.
fixture_stu_count() {  # $1 dir
  git -C "$1/stu.git" rev-list --count main
}
