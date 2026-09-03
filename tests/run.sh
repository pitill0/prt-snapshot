#!/bin/bash

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/prt-snapshot"
TEST_ROOT=""
PASS=0
FAIL=0

say() {
  printf '%s\n' "$*"
}

pass() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1"
}

cleanup() {
  [ -n "$TEST_ROOT" ] && rm -rf -- "$TEST_ROOT"
}

trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || {
  say "tests must run as root so production ownership checks remain active"
  say "try: sudo ./tests/run.sh"
  exit 1
}

new_sandbox() {
  cleanup
  TEST_ROOT="$(mktemp -d /tmp/prt-snapshot-tests.XXXXXX)" || exit 1
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/store"
  chmod 0755 "$TEST_ROOT/store"

  cp "$SOURCE" "$TEST_ROOT/prt-snapshot"
  chmod 0755 "$TEST_ROOT/prt-snapshot"

  # Redirect only the production constants. All normal system utilities remain
  # available after the fake prt-get directory in PATH.
  sed -i \
    -e "s|^PATH=.*|PATH=\"$TEST_ROOT/bin:/usr/sbin:/usr/bin:/sbin:/bin\"|" \
    -e "s|^VARDIR=.*|VARDIR=\"$TEST_ROOT/store\"|" \
    "$TEST_ROOT/prt-snapshot"

  cat > "$TEST_ROOT/bin/prt-get" <<'MOCK'
#!/bin/bash
set -u

STATE="${PRT_TEST_STATE:?}"
LOG="${PRT_TEST_LOG:?}"
PKG_DB="${PRT_TEST_PKG_DB:-}"

recreate_pkg_db() {
  [ -n "$PKG_DB" ] || return 0
  rm -f -- "$PKG_DB"
  : > "$PKG_DB"
}

case "${1:-}" in
  listinst)
    cat "$STATE"
    ;;
  quickdep)
    port="${2:-}"
    if [ "${PRT_TEST_FAIL_QUICKDEP:-}" = "$port" ]; then
      exit 44
    fi

    case "$port" in
      app)
        printf 'lib app\n'
        ;;
      lib)
        printf 'lib\n'
        ;;
      foreign-app)
        printf 'outside foreign-app\n'
        ;;
      *)
        printf '%s\n' "$port"
        ;;
    esac
    ;;
  remove)
    port="${2:-}"
    printf 'remove %s\n' "$port" >> "$LOG"
    recreate_pkg_db
    if [ "${PRT_TEST_FAIL_REMOVE:-}" = "$port" ]; then
      exit 42
    fi
    grep -Fvx -- "$port" "$STATE" > "$STATE.tmp" || true
    mv "$STATE.tmp" "$STATE"
    ;;
  install)
    port="${2:-}"
    printf 'install %s\n' "$port" >> "$LOG"
    recreate_pkg_db
    if [ "${PRT_TEST_FAIL_INSTALL:-}" = "$port" ]; then
      exit 43
    fi
    if ! grep -Fxq -- "$port" "$STATE"; then
      printf '%s\n' "$port" >> "$STATE"
      sort -o "$STATE" "$STATE"
    fi
    ;;
  *)
    printf 'unexpected prt-get command: %s\n' "$*" >&2
    exit 99
    ;;
esac
MOCK
  chmod 0755 "$TEST_ROOT/bin/prt-get"

  : > "$TEST_ROOT/state"
  : > "$TEST_ROOT/log"
  export PRT_TEST_STATE="$TEST_ROOT/state"
  export PRT_TEST_LOG="$TEST_ROOT/log"
  unset PRT_TEST_PKG_DB
  unset PRT_TEST_FAIL_REMOVE PRT_TEST_FAIL_INSTALL PRT_TEST_FAIL_QUICKDEP
}

run_prt() {
  "$TEST_ROOT/prt-snapshot" "$@"
}

assert_file() {
  [ -f "$1" ]
}

assert_not_file() {
  [ ! -e "$1" ]
}

assert_contains() {
  grep -Fq -- "$2" "$1"
}

assert_not_contains() {
  ! grep -Fq -- "$2" "$1"
}

# 1. Snapshot numbering must use max(id)+1, never count+1.
test_gap_does_not_overwrite() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/state"
  printf 'old-one\n' > "$TEST_ROOT/store/1.snap"
  printf 'one\n' > "$TEST_ROOT/store/1.msg"
  printf 'old-three\n' > "$TEST_ROOT/store/3.snap"
  printf 'three\n' > "$TEST_ROOT/store/3.msg"

  if run_prt store "after gap" >/dev/null 2>&1 &&
     assert_file "$TEST_ROOT/store/4.snap" &&
     grep -Fxq 'old-three' "$TEST_ROOT/store/3.snap"; then
    pass "store uses max snapshot id + 1 and preserves existing snapshots"
  else
    fail "store uses max snapshot id + 1 and preserves existing snapshots"
  fi
}

# 2. User-controlled snapshot IDs must never escape the store namespace.
test_invalid_snapshot_id() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/state"

  if ! run_prt restore '../1' >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fq 'invalid snapshot id' "$TEST_ROOT/err" &&
     [ ! -s "$TEST_ROOT/log" ]; then
    pass "restore rejects non-numeric snapshot ids before prt-get"
  else
    fail "restore rejects non-numeric snapshot ids before prt-get"
  fi
}

# 3. The complete restore plan must be validated before any prt-get mutation.
test_invalid_port_name() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'base\nbad/name\n' > "$TEST_ROOT/store/1.snap"
  printf 'malicious\n' > "$TEST_ROOT/store/1.msg"

  if ! run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fq 'invalid port name' "$TEST_ROOT/err" &&
     [ ! -s "$TEST_ROOT/log" ] &&
     grep -Fxq 'extra' "$TEST_ROOT/state" &&
     assert_file "$TEST_ROOT/store/1.snap"; then
    pass "restore validates the complete plan before prt-get"
  else
    fail "restore validates the complete plan before prt-get"
  fi
}

# 4. Failed removals must abort and preserve newer snapshot history.
test_failed_remove_preserves_history() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'base\n' > "$TEST_ROOT/store/1.snap"
  printf 'base\n' > "$TEST_ROOT/store/1.msg"
  printf 'base\nextra\n' > "$TEST_ROOT/store/2.snap"
  printf 'later\n' > "$TEST_ROOT/store/2.msg"
  export PRT_TEST_FAIL_REMOVE='extra'

  if ! run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     assert_contains "$TEST_ROOT/log" 'remove extra' &&
     assert_file "$TEST_ROOT/store/2.snap" &&
     assert_file "$TEST_ROOT/store/2.msg"; then
    pass "failed remove aborts restore without pruning newer snapshots"
  else
    fail "failed remove aborts restore without pruning newer snapshots"
  fi
}

# 5. Failed installs must abort and preserve newer snapshot history.
test_failed_install_preserves_history() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/state"
  printf 'base\nmissing\n' > "$TEST_ROOT/store/1.snap"
  printf 'target\n' > "$TEST_ROOT/store/1.msg"
  printf 'base\n' > "$TEST_ROOT/store/2.snap"
  printf 'later\n' > "$TEST_ROOT/store/2.msg"
  export PRT_TEST_FAIL_INSTALL='missing'

  if ! run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     assert_contains "$TEST_ROOT/log" 'install missing' &&
     assert_file "$TEST_ROOT/store/2.snap" &&
     assert_file "$TEST_ROOT/store/2.msg"; then
    pass "failed install aborts restore without pruning newer snapshots"
  else
    fail "failed install aborts restore without pruning newer snapshots"
  fi
}

# 6. Successful restore may prune only snapshots newer than the target.
test_successful_restore_prunes_newer_history() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'base\n' > "$TEST_ROOT/store/1.snap"
  printf 'base\n' > "$TEST_ROOT/store/1.msg"
  printf 'base\nextra\n' > "$TEST_ROOT/store/2.snap"
  printf 'later\n' > "$TEST_ROOT/store/2.msg"

  if run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fxq 'base' "$TEST_ROOT/state" &&
     assert_file "$TEST_ROOT/store/1.snap" &&
     assert_not_file "$TEST_ROOT/store/2.snap" &&
     assert_not_file "$TEST_ROOT/store/2.msg"; then
    pass "successful restore prunes only snapshots newer than target"
  else
    fail "successful restore prunes only snapshots newer than target"
  fi
}

# 7. Temporary files and locks must not survive a failed restore.
test_failed_restore_cleans_temporary_state() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'base\n' > "$TEST_ROOT/store/1.snap"
  printf 'base\n' > "$TEST_ROOT/store/1.msg"
  export PRT_TEST_FAIL_REMOVE='extra'

  run_prt restore 1 --yes >/dev/null 2>&1 || true

  if [ ! -e "$TEST_ROOT/store/.lock" ] &&
     ! find "$TEST_ROOT/store" -maxdepth 1 -type f \( -name '.current.*' -o -name '.restore.*' -o -name '.install.*' -o -name '.snapshot.*' -o -name '.message.*' \) | grep -q .; then
    pass "failed restore cleans temporary files and lock"
  else
    fail "failed restore cleans temporary files and lock"
  fi
}

# 8. clean must leave unrelated files untouched.
test_clean_only_removes_snapshot_namespace() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/store/1.snap"
  printf 'base\n' > "$TEST_ROOT/store/1.msg"
  printf 'keep\n' > "$TEST_ROOT/store/notes.txt"
  printf 'keep\n' > "$TEST_ROOT/store/not-a-number.snap"

  if run_prt clean >/dev/null 2>&1 &&
     assert_not_file "$TEST_ROOT/store/1.snap" &&
     assert_not_file "$TEST_ROOT/store/1.msg" &&
     assert_file "$TEST_ROOT/store/notes.txt" &&
     assert_file "$TEST_ROOT/store/not-a-number.snap"; then
    pass "clean removes only numeric snapshot files"
  else
    fail "clean removes only numeric snapshot files"
  fi
}

# 9. dry-run must show the plan without mutating packages or snapshot history.
test_restore_dry_run_is_read_only() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'base\n' > "$TEST_ROOT/store/1.snap"
  printf 'base\n' > "$TEST_ROOT/store/1.msg"
  printf 'base\nextra\n' > "$TEST_ROOT/store/2.snap"
  printf 'later\n' > "$TEST_ROOT/store/2.msg"

  if run_prt restore 1 --dry-run >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fq 'Restore plan for snapshot 1' "$TEST_ROOT/out" &&
     grep -Fq 'Remove (1):' "$TEST_ROOT/out" &&
     grep -Fq 'extra' "$TEST_ROOT/out" &&
     [ ! -s "$TEST_ROOT/log" ] &&
     grep -Fxq 'extra' "$TEST_ROOT/state" &&
     assert_file "$TEST_ROOT/store/2.snap"; then
    pass "restore --dry-run shows the plan without mutating state"
  else
    fail "restore --dry-run shows the plan without mutating state"
  fi
}

# 10. Non-interactive restore must require explicit --yes or --dry-run.
test_noninteractive_restore_requires_opt_in() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'base\n' > "$TEST_ROOT/store/1.snap"
  printf 'base\n' > "$TEST_ROOT/store/1.msg"
  printf 'base\nextra\n' > "$TEST_ROOT/store/2.snap"
  printf 'later\n' > "$TEST_ROOT/store/2.msg"

  if ! run_prt restore 1 </dev/null >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fq 'restore requires confirmation' "$TEST_ROOT/err" &&
     [ ! -s "$TEST_ROOT/log" ] &&
     grep -Fxq 'extra' "$TEST_ROOT/state" &&
     assert_file "$TEST_ROOT/store/2.snap"; then
    pass "non-interactive restore requires explicit opt-in"
  else
    fail "non-interactive restore requires explicit opt-in"
  fi
}

# 11. show must expose snapshot metadata and package membership.
test_show_snapshot_details() {
  new_sandbox
  printf 'alpha\nbeta\n' > "$TEST_ROOT/store/3.snap"
  printf 'before test\nsecond line\n' > "$TEST_ROOT/store/3.msg"

  if run_prt show 3 >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fxq 'Snapshot: 3' "$TEST_ROOT/out" &&
     grep -Fq 'Created: ' "$TEST_ROOT/out" &&
     grep -Fxq 'Message: before test second line ' "$TEST_ROOT/out" &&
     grep -Fxq 'Packages (2):' "$TEST_ROOT/out" &&
     grep -Fxq '  alpha' "$TEST_ROOT/out" &&
     grep -Fxq '  beta' "$TEST_ROOT/out" &&
     [ ! -s "$TEST_ROOT/log" ]; then
    pass "show displays snapshot metadata and packages"
  else
    fail "show displays snapshot metadata and packages"
  fi
}

# 12. --packages must emit only validated package names.
test_show_packages_only() {
  new_sandbox
  printf 'alpha\nbeta\n' > "$TEST_ROOT/store/4.snap"
  printf 'message\n' > "$TEST_ROOT/store/4.msg"

  if run_prt show 4 --packages >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     printf 'alpha\nbeta\n' | cmp -s - "$TEST_ROOT/out" &&
     [ ! -s "$TEST_ROOT/log" ]; then
    pass "show --packages emits only package names"
  else
    fail "show --packages emits only package names"
  fi
}

# 13. show must reject corrupt snapshot package data before output.
test_show_rejects_invalid_package_data() {
  new_sandbox
  printf 'alpha\nbad/name\n' > "$TEST_ROOT/store/5.snap"
  printf 'corrupt\n' > "$TEST_ROOT/store/5.msg"

  if ! run_prt show 5 >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fq 'invalid port name' "$TEST_ROOT/err" &&
     [ ! -s "$TEST_ROOT/out" ] &&
     [ ! -s "$TEST_ROOT/log" ]; then
    pass "show validates snapshot data before producing output"
  else
    fail "show validates snapshot data before producing output"
  fi
}

# 14. Missing packages must be installed in dependency order.
test_restore_orders_target_dependencies() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/state"
  printf 'app\nbase\nlib\n' > "$TEST_ROOT/store/1.snap"
  printf 'target\n' > "$TEST_ROOT/store/1.msg"

  if run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     printf 'install lib\ninstall app\n' | cmp -s - "$TEST_ROOT/log" &&
     grep -Fxq 'lib' "$TEST_ROOT/state" &&
     grep -Fxq 'app' "$TEST_ROOT/state"; then
    pass "restore installs target packages in dependency order"
  else
    fail "restore installs target packages in dependency order"
  fi
}

# 15. Dependencies outside the target snapshot must never be installed.
test_restore_does_not_expand_membership() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/state"
  printf 'base\nforeign-app\n' > "$TEST_ROOT/store/1.snap"
  printf 'target\n' > "$TEST_ROOT/store/1.msg"

  if run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     assert_contains "$TEST_ROOT/log" 'install foreign-app' &&
     assert_not_contains "$TEST_ROOT/log" 'install outside' &&
     ! grep -Fxq 'outside' "$TEST_ROOT/state"; then
    pass "restore dependency ordering never expands snapshot membership"
  else
    fail "restore dependency ordering never expands snapshot membership"
  fi
}

# 16. Dependency-order resolution failure must happen before any mutation.
test_quickdep_failure_precedes_mutation() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'app\nbase\nlib\n' > "$TEST_ROOT/store/1.snap"
  printf 'target\n' > "$TEST_ROOT/store/1.msg"
  printf 'base\nextra\n' > "$TEST_ROOT/store/2.snap"
  printf 'later\n' > "$TEST_ROOT/store/2.msg"
  export PRT_TEST_FAIL_QUICKDEP='app'

  if ! run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fq 'could not resolve dependency order' "$TEST_ROOT/err" &&
     [ ! -s "$TEST_ROOT/log" ] &&
     grep -Fxq 'extra' "$TEST_ROOT/state" &&
     assert_file "$TEST_ROOT/store/2.snap"; then
    pass "dependency resolution failure aborts before mutation"
  else
    fail "dependency resolution failure aborts before mutation"
  fi
}

# 17. Informational commands must work before the snapshot store exists.
test_help_and_version_without_store() {
  new_sandbox
  rm -rf -- "$TEST_ROOT/store"

  if run_prt help >"$TEST_ROOT/help.out" 2>"$TEST_ROOT/help.err" &&
     run_prt version >"$TEST_ROOT/version.out" 2>"$TEST_ROOT/version.err" &&
     grep -Fq 'Usage:' "$TEST_ROOT/help.out" &&
     grep -Fq 'v0.5' "$TEST_ROOT/version.out"; then
    pass "help and version do not require an initialized snapshot store"
  else
    fail "help and version do not require an initialized snapshot store"
  fi
}

# 18. Invalid commands and options must return a failing exit status.
test_invalid_cli_returns_failure() {
  new_sandbox

  if ! run_prt nonsense >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     grep -Fq 'Usage:' "$TEST_ROOT/out" &&
     ! run_prt show 1 --invalid >"$TEST_ROOT/out2" 2>"$TEST_ROOT/err2"; then
    pass "invalid CLI usage returns non-zero"
  else
    fail "invalid CLI usage returns non-zero"
  fi
}

# 19. dry-run must display the same dependency-aware install order.
test_dry_run_shows_dependency_order() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/state"
  printf 'app\nbase\nlib\n' > "$TEST_ROOT/store/1.snap"
  printf 'target\n' > "$TEST_ROOT/store/1.msg"

  if run_prt restore 1 --dry-run >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &&
     [ ! -s "$TEST_ROOT/log" ] &&
     awk '
       /^  Install \(2\):$/ {in_install=1; next}
       in_install && /^    / {
         sub(/^    /, "")
         print
       }
     ' "$TEST_ROOT/out" > "$TEST_ROOT/install-order" &&
     printf 'lib\napp\n' | cmp -s - "$TEST_ROOT/install-order"; then
    pass "dry-run displays dependency-aware install order"
  else
    fail "dry-run displays dependency-aware install order"
  fi
}

# 20. Mutating prt-get calls must not inherit a restrictive caller umask.
test_restore_does_not_restrict_pkgutils_db() {
  new_sandbox
  printf 'base\nextra\n' > "$TEST_ROOT/state"
  printf 'base\nmissing\n' > "$TEST_ROOT/store/1.snap"
  printf 'target\n' > "$TEST_ROOT/store/1.msg"
  export PRT_TEST_PKG_DB="$TEST_ROOT/pkg-db"

  if (umask 077; run_prt restore 1 --yes >"$TEST_ROOT/out" 2>"$TEST_ROOT/err") &&
     [ -f "$TEST_ROOT/pkg-db" ] &&
     [ "$(stat -c '%a' "$TEST_ROOT/pkg-db")" = "644" ] &&
     assert_contains "$TEST_ROOT/log" 'remove extra' &&
     assert_contains "$TEST_ROOT/log" 'install missing'; then
    pass "restore isolates pkgutils from restrictive caller umask"
  else
    fail "restore isolates pkgutils from restrictive caller umask"
  fi
}

# 21. Snapshot-owned persistent files must remain private without a global umask.
test_store_keeps_snapshot_files_private() {
  new_sandbox
  printf 'base\n' > "$TEST_ROOT/state"

  if (umask 022; run_prt store "private snapshot" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err") &&
     [ "$(stat -c '%a' "$TEST_ROOT/store/1.snap")" = "600" ] &&
     [ "$(stat -c '%a' "$TEST_ROOT/store/1.msg")" = "600" ]; then
    pass "store explicitly keeps snapshot files private"
  else
    fail "store explicitly keeps snapshot files private"
  fi
}

say "1..21"
test_gap_does_not_overwrite
test_invalid_snapshot_id
test_invalid_port_name
test_failed_remove_preserves_history
test_failed_install_preserves_history
test_successful_restore_prunes_newer_history
test_failed_restore_cleans_temporary_state
test_clean_only_removes_snapshot_namespace
test_restore_dry_run_is_read_only
test_noninteractive_restore_requires_opt_in
test_show_snapshot_details
test_show_packages_only
test_show_rejects_invalid_package_data
test_restore_orders_target_dependencies
test_restore_does_not_expand_membership
test_quickdep_failure_precedes_mutation
test_help_and_version_without_store
test_invalid_cli_returns_failure
test_dry_run_shows_dependency_order
test_restore_does_not_restrict_pkgutils_db
test_store_keeps_snapshot_files_private

say ""
say "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
