#!/usr/bin/env bash
# tests/cases/cli-gate-land.sh — the refusal contracts of the three openbuilder
# commands that spend money or destroy work: `dispatch` (the epic gate), `land`
# (the only merge path) and `review --watch` (the only unattended reviewer).
#
# Nothing here touches the network, AWS or GitHub. `gh`, `aws`, `omp` and
# `sleep` are stubbed first on PATH, `ob-gate` is stubbed next to the copy of the
# CLI under test, and every stub appends its own argv to one call log. That log
# is the evidence for the assertion each refusal test really exists for: a
# refusal must make no mutating call at all — no push, no merge, no ref
# deletion, no label edit, no reviewer session.
#
# `origin` is a local bare repository reached through a stubbed ssh command, so
# the clone's origin URL is still ssh://git@github.com/... (the CLI refuses any
# other host) while fetch and push stay on this machine. The bare repo's
# pre-receive hook logs every ref anyone tries to push, which is what makes
# "no plan branch was created" provable instead of asserted by absence.

# shellcheck source=tests/lib.sh
source "$TESTS_LIB"

# ---------------------------------------------------------------------------
# Guard: the contracts under test are not on every branch yet (PR #8).
# ---------------------------------------------------------------------------

CLI_SRC="$TESTS_ROOT/local/bin/openbuilder"
for _fn in 'cmd_dispatch()' 'cmd_land()' 'ob_review_watch()' 'ob_gate()'; do
    grep -qF -e "$_fn" "$CLI_SRC" 2>/dev/null ||
        skip "cli gate/land not on this branch yet (PR #8)"
done

# ---------------------------------------------------------------------------
# The world: a fake repo root holding the CLI under test and the ob-gate stub,
# a stub PATH, a fixture/call-log directory, a workspace and a cache.
# ---------------------------------------------------------------------------

FAKE_ROOT="$(tmpdir)"
STUBBIN="$(tmpdir)"
FIX="$(tmpdir)"
WORKSPACE_DIR="$(tmpdir)"
CACHE_DIR="$(tmpdir)"
RUN_DIR="$(tmpdir)"

REPO='obtest/widgets'
KEY='obtest__widgets'
SLUG='widget-list'
EPIC='widgets'
PR='42'
DESIGN="openbuilder/design/$EPIC"
PLAN_BRANCH="openbuilder/plan/$SLUG"
WORK_BRANCH="openbuilder/work/$SLUG"
BACKLOG=".openbuilder/backlog/$SLUG"
CLONE="$WORKSPACE_DIR/$KEY"
REVIEW_DIR="$CACHE_DIR/openbuilder/review"
MARKER="$REVIEW_DIR/${KEY}__$PR"
# The one `pr view` route land uses, keyed by its --json spec.
PRVIEW="pr-view-headRefName-labels-state-title-baseRefName"

mkdir -p "$FAKE_ROOT/local/bin"
CLI="$FAKE_ROOT/local/bin/openbuilder"
cp "$CLI_SRC" "$CLI"
chmod +x "$CLI"

export OB_STUB_DIR="$FIX"
export OB_CALL_LOG="$FIX/calls.log"
export OB_STUB_MAX_SLEEPS=6
export PATH="$STUBBIN:$PATH"
export XDG_CACHE_HOME="$CACHE_DIR"
export OPENBUILDER_WORKSPACE="$WORKSPACE_DIR"
export OPENBUILDER_OWNER='obtest'
export OPENBUILDER_REGION='eu-central-1'
export OPENBUILDER_INSTANCE_ID='i-0123456789abcdef0'
export OPENBUILDER_GH_HOST='github.com'
unset OPENBUILDER_TARGET_REPO OPENBUILDER_AWS_PROFILE OPENBUILDER_MAX_ATTEMPTS
: >"$OB_CALL_LOG"

# ---------------------------------------------------------------------------
# The stubs. One script, dispatched on its own name; installed as gh/aws/omp/
# sleep on PATH and as ob-gate beside the CLI (the CLI calls it by path).
#
# Fixture protocol, all files in $OB_STUB_DIR:
#   <tool>.<route>        stdout for that route
#   <tool>.<route>.<n>    stdout for the n-th call of that route (wins)
#   <tool>.<route>[.<n>].rc   exit status (default 0)
# A route with no fixture at all is a hard error (exit 99): a call nobody
# scripted must never be answered with a silent, successful nothing.
# ---------------------------------------------------------------------------

cat >"$FIX/stub" <<'STUB'
#!/usr/bin/env bash
set -u
tool=${0##*/}
all="$*"

{
    printf '%s' "$tool"
    for _a in "$@"; do printf ' %s' "$_a"; done
    printf '\n'
} >>"$OB_CALL_LOG"

_bump() {
    local f="$OB_STUB_DIR/.n.$tool.$1" n=0
    [ -f "$f" ] && n=$(cat "$f")
    n=$((n + 1))
    printf '%s\n' "$n" >"$f"
    printf '%s' "$n"
}

route=''
case $tool in
sleep)
    # The watch loop is `while :`; this is its only bound. A test that scripted
    # too few label responses dies here instead of spinning forever.
    n=$(_bump sleep)
    if [ "$n" -gt "${OB_STUB_MAX_SLEEPS:-6}" ]; then
        printf 'stub sleep: %s poll iterations with no exit; killing the cli\n' "$n" >&2
        kill -TERM "$PPID" 2>/dev/null || true
        exit 143
    fi
    exit 0
    ;;
omp) route=run ;;
ob-gate) route=${1:-none} ;;
aws) route="${1:-none}-${2:-none}" ;;
gh)
    case ${1:-} in
    pr)
        case ${2:-} in
        view)
            spec='' prev=''
            for _a in "$@"; do
                if [ "$prev" = '--json' ]; then
                    spec=$_a
                    break
                fi
                prev=$_a
            done
            route="pr-view-${spec//,/-}"
            ;;
        *) route="pr-${2:-none}" ;;
        esac
        ;;
    api)
        case $all in
        *' DELETE '*) route=api-delete ;;
        *plan.md*) route=api-plan-md ;;
        *state.json*) route=api-state-json ;;
        *matching-refs*) route=api-matching-refs ;;
        *) route=api ;;
        esac
        ;;
    label) route=label ;;
    repo) route="repo-${2:-none}" ;;
    *) route=${1:-none} ;;
    esac
    ;;
esac

base=''
n=$(_bump "$route")
if [ -f "$OB_STUB_DIR/$tool.$route.$n" ] || [ -f "$OB_STUB_DIR/$tool.$route.$n.rc" ]; then
    base="$OB_STUB_DIR/$tool.$route.$n"
elif [ -f "$OB_STUB_DIR/$tool.$route" ] || [ -f "$OB_STUB_DIR/$tool.$route.rc" ]; then
    base="$OB_STUB_DIR/$tool.$route"
else
    printf 'stub %s: no fixture for route %s (call %s: %s)\n' "$tool" "$route" "$n" "$all" >&2
    exit 99
fi

rc=0
[ -f "$base.rc" ] && rc=$(cat "$base.rc")
[ -f "$base" ] && cat "$base"

# `ob-gate stage` is the one stub with a side effect, because the invariant
# dispatch checks is precisely whether that side effect reached the branch.
if [ "$tool" = 'ob-gate' ] && [ "${1:-}" = 'stage' ] && [ "$rc" = '0' ]; then
    effect='none'
    [ -f "$OB_STUB_DIR/ob-gate.stage.effect" ] &&
        effect=$(cat "$OB_STUB_DIR/ob-gate.stage.effect")
    if [ "$effect" = 'commit' ]; then
        # cwd is the clone: ob_gate runs us there on purpose.
        epic=${2:-} stage=${3:-}
        f=".openbuilder/epics/$epic/state.json"
        mkdir -p "$(dirname "$f")"
        if [ -f "$f" ]; then
            jq --arg s "$stage" '.stage = $s' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
        else
            jq -n --arg e "$epic" --arg s "$stage" \
                '{epic: $e, stage: $s, slugs: []}' >"$f"
        fi
        git add -- "$f" >/dev/null
        git commit -q -m "gate: stage=$stage" >/dev/null
        git push -q origin "HEAD:refs/heads/$(git rev-parse --abbrev-ref HEAD)"
    fi
fi

exit "$rc"
STUB
chmod +x "$FIX/stub"
for _tool in gh aws omp sleep; do
    cp "$FIX/stub" "$STUBBIN/$_tool"
done
cp "$FIX/stub" "$FAKE_ROOT/local/bin/ob-gate"

# The ssh transport: origin stays a github.com URL, the bytes stay local.
cat >"$FIX/git-ssh" <<'SSH'
#!/usr/bin/env bash
bare=$(cat "$OB_STUB_DIR/bare-path")
cmd=''
for a in "$@"; do cmd=$a; done
printf 'git-ssh %s\n' "$cmd" >>"$OB_CALL_LOG"
case $cmd in
*git-receive-pack*) exec git receive-pack "$bare" ;;
*) exec git upload-pack "$bare" ;;
esac
SSH
chmod +x "$FIX/git-ssh"

# ---------------------------------------------------------------------------
# Fixture and call-log helpers
# ---------------------------------------------------------------------------

fx() { cat >"$FIX/$1"; }                              # body on stdin
fx_line() { printf '%s\n' "$2" >"$FIX/$1"; }          # one-line stdout
fx_ok() { : >"$FIX/$1"; }                             # empty stdout, exit 0
fx_rc() { printf '%s\n' "$2" >"$FIX/$1.rc"; }         # exit status only

log_clear() { : >"$OB_CALL_LOG"; }
log_read() { cat "$OB_CALL_LOG" 2>/dev/null; }
log_count() { grep -cF -e "$1" "$OB_CALL_LOG" 2>/dev/null || true; }

# Every fixture and counter goes, then the calls every command makes on its way
# to a refusal are re-scripted: the instance is up and the labels converge.
fx_reset() {
    rm -f "$FIX"/gh.* "$FIX"/aws.* "$FIX"/omp.* "$FIX"/ob-gate.* "$FIX"/.n.*
    fx_line aws.ec2-describe-instances running
    fx_line aws.ssm-describe-instance-information 1
    fx_line aws.ssm-send-command cmd-0001
    fx aws.ssm-list-command-invocations <<'EOF'
{"CommandInvocations":[{"Status":"Success","CommandPlugins":[{"StandardOutputContent":"pruned the worktree and the state directory\n","StandardErrorContent":"","ResponseCode":0}]}]}
EOF
    fx_ok gh.label
    log_clear
}

# assert_no_mutation <label> — the assertion every refusal test exists for.
# One result, listing whatever leaked, because "it refused" is worthless if it
# refused after merging.
assert_no_mutation() {
    local label=$1 log leaked='' pat
    log=$(log_read)
    for pat in 'git-push ' 'git-receive-pack' 'gh pr merge' 'gh api -X DELETE' \
        'gh pr edit' 'gh pr comment' 'aws ssm send-command' \
        'aws ec2 start-instances' 'omp '; do
        case $log in
        *"$pat"*) leaked="$leaked $pat" ;;
        esac
    done
    assert_eq '' "$leaked" "$label"
}

# run_ob [args...] / run_ob_in <stdin-line> [args...] — run the CLI under test
# from a scratch cwd (so no real ./.openbuilder.local is ever sourced), with
# stdout and stderr merged into OUT and its status in RC.
OUT=''
RC=0
run_ob() {
    OUT=$( (cd "$RUN_DIR" && "$CLI" "$@") </dev/null 2>&1 )
    RC=$?
}
run_ob_in() {
    local input=$1
    shift
    OUT=$(printf '%s\n' "$input" | (cd "$RUN_DIR" && "$CLI" "$@") 2>&1)
    RC=$?
}

# ---------------------------------------------------------------------------
# world_new — a local bare "origin" plus a clone shaped exactly like the one
# `openbuilder plan` leaves behind: on the design branch, with a committed
# backlog for one slug and an epic state.json at stage=backlog.
# ---------------------------------------------------------------------------

BARE=''
world_new() {
    local w seed
    {
        w=$(tmpdir)
        BARE="$w/origin.git"
        git init -q --bare "$BARE"
        printf '%s\n' "$BARE" >"$FIX/bare-path"

        # Every ref anyone pushes, wanted or not, lands in the call log.
        cat >"$BARE/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
    printf 'git-push %s\n' "$ref" >>"$OB_CALL_LOG"
done
HOOK
        chmod +x "$BARE/hooks/pre-receive"

        seed="$w/seed"
        git init -q -b main "$seed"
        git -C "$seed" config user.email 'tests@openbuilder.invalid'
        git -C "$seed" config user.name 'openbuilder tests'
        git -C "$seed" config commit.gpgsign false
        printf 'seed\n' >"$seed/README.md"
        git -C "$seed" add -A
        git -C "$seed" commit -q -m 'seed'
        git -C "$seed" push -q "$BARE" main

        git -C "$seed" checkout -q -b "$DESIGN"
        mkdir -p "$seed/.openbuilder/epics/$EPIC" "$seed/$BACKLOG"
        printf '{"epic":"%s","stage":"backlog","slugs":["%s"]}\n' "$EPIC" "$SLUG" \
            >"$seed/.openbuilder/epics/$EPIC/state.json"
        printf '# plan: %s\n\n- epic: %s\n- slug: %s\n' "$SLUG" "$EPIC" "$SLUG" \
            >"$seed/$BACKLOG/plan.md"
        printf '# story: list the widgets\n\n## acceptance\n\n- it lists them\n' \
            >"$seed/$BACKLOG/story-01.md"
        git -C "$seed" add -A
        git -C "$seed" commit -q -m "backlog: $SLUG"
        git -C "$seed" push -q "$BARE" "$DESIGN"

        # A work branch, so `review --watch` exercises its checkout path.
        git -C "$seed" checkout -q -b "$WORK_BRANCH"
        printf 'work\n' >>"$seed/README.md"
        git -C "$seed" commit -q -am 'work'
        git -C "$seed" push -q "$BARE" "$WORK_BRANCH"

        rm -rf "$CLONE"
        mkdir -p "$(dirname "$CLONE")"
        git init -q -b main "$CLONE"
        git -C "$CLONE" config user.email 'tests@openbuilder.invalid'
        git -C "$CLONE" config user.name 'openbuilder tests'
        git -C "$CLONE" config commit.gpgsign false
        git -C "$CLONE" config core.sshCommand "$FIX/git-ssh"
        git -C "$CLONE" remote add origin "ssh://git@github.com/$REPO"
        git -C "$CLONE" fetch -q origin
        git -C "$CLONE" checkout -q -B main --track origin/main
        git -C "$CLONE" checkout -q -B "$DESIGN" --track "origin/$DESIGN"
    } >&2
    fx_reset
}

# ===========================================================================
# dispatch — the gate
# ===========================================================================

# 1. no local clone -> the fix is `plan`, not `git clone`.
world_new
rm -rf "$CLONE"
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when there is no local clone'
assert_contains "no local clone at $CLONE" "$OUT" \
    'dispatch: the no-clone refusal names the directory it looked in'
assert_contains "run 'openbuilder plan $REPO <epic>' first" "$OUT" \
    'dispatch: the no-clone refusal names plan as the fix'
assert_no_mutation 'dispatch: no-clone refusal makes no mutating call'

# 2a. backlog directory absent.
world_new
rm -rf "${CLONE:?}/$BACKLOG"
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when the backlog directory is absent'
assert_contains "$BACKLOG does not exist in $CLONE" "$OUT" \
    'dispatch: the absent-backlog refusal names the missing directory'
assert_no_mutation 'dispatch: absent-backlog refusal makes no mutating call'

# 2b. plan.md absent.
world_new
rm -f "$CLONE/$BACKLOG/plan.md"
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when plan.md is absent'
assert_contains "$BACKLOG/plan.md is missing — the planner did not finish" "$OUT" \
    'dispatch: the missing-plan.md refusal blames the planner, not the operator'
assert_no_mutation 'dispatch: missing-plan.md refusal makes no mutating call'

# 2c. zero story cards.
world_new
rm -f "$CLONE/$BACKLOG"/story-*.md
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when the backlog has no story cards'
assert_contains "$BACKLOG contains no story-*.md cards" "$OUT" \
    'dispatch: the no-cards refusal says there is nothing to implement'
assert_no_mutation 'dispatch: no-cards refusal makes no mutating call'

# 3. plan.md with no '- epic:' line.
world_new
printf '# plan: %s\n\n- slug: %s\n' "$SLUG" "$SLUG" >"$CLONE/$BACKLOG/plan.md"
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses a plan.md with no epic line'
assert_contains "dispatch cannot tell which epic gates this slug" "$OUT" \
    'dispatch: the no-epic-line refusal says it cannot tell which epic gates the slug'
assert_no_mutation 'dispatch: no-epic-line refusal makes no mutating call'

# 4. clone on a branch other than the epic's design branch. dispatch checks the
# backlog before the branch, so this needs a branch that carries the backlog: on
# a branch without it (main) the earlier, equally correct refusal wins.
world_new
git -C "$CLONE" checkout -q -b scratch
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when the clone is not on the design branch'
assert_contains "is on branch scratch, not the design branch $DESIGN for epic $EPIC" "$OUT" \
    'dispatch: the wrong-branch refusal names both branches'
assert_contains "Run: openbuilder plan $REPO $EPIC" "$OUT" \
    'dispatch: the wrong-branch refusal names the plan command that fixes it'
assert_no_mutation 'dispatch: wrong-branch refusal makes no mutating call'

# 5a. uncommitted change inside the backlog.
world_new
printf '\n- sneaked in after the approval\n' >>"$CLONE/$BACKLOG/plan.md"
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses an uncommitted change in the backlog'
assert_contains "$BACKLOG has uncommitted or untracked changes in $CLONE" "$OUT" \
    'dispatch: the dirty-backlog refusal names the backlog and the clone'
assert_contains 'An approval covers committed bytes only.' "$OUT" \
    'dispatch: the dirty-backlog refusal explains that approvals cover committed bytes'
assert_no_mutation 'dispatch: dirty-backlog refusal makes no mutating call'

# 5b. untracked extra story card — the exact case rule 4b re-checks.
world_new
printf '# story: sneaked in\n' >"$CLONE/$BACKLOG/story-99.md"
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses an untracked story card in the backlog'
assert_contains 'story-99.md' "$OUT" \
    'dispatch: the untracked-card refusal names the untracked card'
assert_no_mutation 'dispatch: untracked-card refusal makes no mutating call'

# 6a. ob-gate exit 3 — the approval is void.
world_new
fx_rc ob-gate.verify 3
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when ob-gate reports a void approval (exit 3)'
assert_contains "the recorded backlog approval for $SLUG no longer matches the files on $DESIGN" "$OUT" \
    'dispatch: the void-approval refusal says the approved files changed'
assert_contains "ob-gate record $EPIC backlog $SLUG)" "$OUT" \
    'dispatch: the void-approval refusal quotes the ob-gate record fix'
assert_not_contains "no backlog approval is recorded" "$OUT" \
    'dispatch: a void approval is not reported as a missing one'
assert_no_mutation 'dispatch: void-approval refusal makes no mutating call'

# 6b. ob-gate exit 4 — nothing was ever recorded.
world_new
fx_rc ob-gate.verify 4
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when ob-gate reports no approval (exit 4)'
assert_contains "no backlog approval is recorded for $SLUG in .openbuilder/epics/$EPIC/state.json." "$OUT" \
    'dispatch: the no-approval refusal names the state.json it read'
assert_contains "ob-gate record $EPIC backlog $SLUG)" "$OUT" \
    'dispatch: the no-approval refusal quotes the ob-gate record fix'
assert_not_contains "no longer matches the files" "$OUT" \
    'dispatch: a missing approval is not reported as a void one'
assert_no_mutation 'dispatch: no-approval refusal makes no mutating call'

# 7. The ordering invariant: `ob-gate stage` returned 0 but state.json on the
# design branch does not say dispatched. A plan branch cut here is declined by
# rule 4b on every poll pass, forever, silently.
world_new
fx_rc ob-gate.verify 0
fx_rc ob-gate.stage 0
fx_line ob-gate.stage.effect none
run_ob dispatch "$REPO" "$SLUG"
assert_eq 1 "$RC" 'dispatch: refuses when state.json does not say dispatched after ob-gate stage'
assert_contains "state.json on $DESIGN still says stage='backlog'" "$OUT" \
    'dispatch: the ordering refusal quotes the stage it actually found'
assert_contains "rule 4b would decline it on every poll pass forever" "$OUT" \
    'dispatch: the ordering refusal explains the silent-decline trap'
assert_not_contains 'git-push refs/heads/openbuilder/plan/' "$(log_read)" \
    'dispatch: the ordering refusal pushes no plan ref (call log)'
assert_eq '' "$(git --git-dir="$BARE" for-each-ref --format='%(refname)' 'refs/heads/openbuilder/plan/*')" \
    'dispatch: the ordering refusal leaves no plan branch on origin'
assert_eq '' "$(git -C "$CLONE" for-each-ref --format='%(refname)' 'refs/heads/openbuilder/plan/*')" \
    'dispatch: the ordering refusal leaves no local plan branch either'

# 8. Happy path: exactly one push, and the ref is exactly openbuilder/plan/<slug>.
world_new
fx_rc ob-gate.verify 0
fx_rc ob-gate.stage 0
fx_line ob-gate.stage.effect commit
run_ob dispatch "$REPO" "$SLUG"
assert_eq 0 "$RC" 'dispatch: a gated slug dispatches'
assert_contains "Dispatched $REPO :: $SLUG" "$OUT" \
    'dispatch: the happy path reports what it dispatched'
assert_eq 1 "$(log_count "git-push refs/heads/$PLAN_BRANCH")" \
    'dispatch: the plan branch is pushed exactly once'
assert_eq "refs/heads/$PLAN_BRANCH" \
    "$(git --git-dir="$BARE" for-each-ref --format='%(refname)' 'refs/heads/openbuilder/plan/*')" \
    'dispatch: the pushed ref is exactly openbuilder/plan/<slug>'

# ===========================================================================
# land — the merge path
# ===========================================================================

# land makes no local git call at all; it reads plan.md and state.json over the
# API. So these tests need fixtures, not a clone.
land_view() { # <head> <state> <labels-json>
    printf '{"headRefName":"%s","state":"%s","title":"add the widget list","baseRefName":"main","labels":%s}\n' \
        "$1" "$2" "$3" >"$FIX/gh.$PRVIEW"
}
land_plan_md() {
    printf '# plan: %s\n\n- epic: %s\n' "$SLUG" "$EPIC" >"$FIX/gh.api-plan-md"
}
land_state_json() {
    printf '{"epic":"%s","stage":"dispatched","slugs":["%s"]}\n' "$EPIC" "$SLUG" \
        >"$FIX/gh.api-state-json"
}

# 1. no openbuilder:approved label.
fx_reset
land_view "$WORK_BRANCH" OPEN '[{"name":"openbuilder:awaiting-review"}]'
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses a pull request that is not labelled approved'
assert_contains "is not labelled openbuilder:approved; land never merges an unapproved pull request" "$OUT" \
    'land: the unapproved refusal says land never merges an unapproved pull request'
assert_eq 0 "$(log_count 'gh pr merge')" \
    'land: the unapproved refusal makes no pr merge call'
assert_no_mutation 'land: unapproved refusal makes no mutating call'

# 2a. state is not OPEN.
fx_reset
land_view "$WORK_BRANCH" MERGED '[{"name":"openbuilder:approved"}]'
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses a pull request that is not OPEN'
assert_contains "is MERGED, not OPEN; there is nothing to land" "$OUT" \
    'land: the not-OPEN refusal names the state it saw'
assert_no_mutation 'land: not-OPEN refusal makes no mutating call'

# 2b. head branch is not under openbuilder/work/.
fx_reset
land_view 'feature/hand-written' OPEN '[{"name":"openbuilder:approved"}]'
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses a head branch outside openbuilder/work/'
assert_contains "the head branch of $REPO#$PR is 'feature/hand-written', not under openbuilder/work/" "$OUT" \
    'land: the foreign-branch refusal names the branch it saw'
assert_no_mutation 'land: foreign-branch refusal makes no mutating call'

# 3a. plan.md unreadable.
fx_reset
land_view "$WORK_BRANCH" OPEN '[{"name":"openbuilder:approved"}]'
fx_rc gh.api-plan-md 1
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses when plan.md cannot be read'
assert_contains "cannot read $BACKLOG/plan.md on $PLAN_BRANCH; land cannot tell which epic to clean up" "$OUT" \
    'land: the unreadable-plan.md refusal will not guess the epic'
assert_no_mutation 'land: unreadable-plan.md refusal makes no mutating call'

# 3b. plan.md without an '- epic:' line.
fx_reset
land_view "$WORK_BRANCH" OPEN '[{"name":"openbuilder:approved"}]'
printf '# plan: %s\n\n- slug: %s\n' "$SLUG" "$SLUG" >"$FIX/gh.api-plan-md"
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses a plan.md with no epic line'
assert_contains "has no '- epic:' line; land cannot tell which epic to clean up" "$OUT" \
    'land: the no-epic-line refusal will not guess the epic'
assert_no_mutation 'land: no-epic-line refusal makes no mutating call'

# 4a. state.json unreadable.
fx_reset
land_view "$WORK_BRANCH" OPEN '[{"name":"openbuilder:approved"}]'
land_plan_md
fx_rc gh.api-state-json 1
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses when state.json cannot be read'
assert_contains "cannot read .openbuilder/epics/$EPIC/state.json on $DESIGN; land will not delete branches it cannot account for" "$OUT" \
    'land: the unreadable-state.json refusal will not delete unaccountable branches'
assert_no_mutation 'land: unreadable-state.json refusal makes no mutating call'

# 4b. state.json readable but without a slugs array — same contract, other path.
fx_reset
land_view "$WORK_BRANCH" OPEN '[{"name":"openbuilder:approved"}]'
land_plan_md
fx_line gh.api-state-json '{"epic":"widgets","stage":"dispatched"}'
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses a state.json with no slugs array'
assert_contains "land will not delete branches it cannot account for" "$OUT" \
    'land: an unparseable state.json refuses like an unreadable one'
assert_no_mutation 'land: unparseable-state.json refusal makes no mutating call'

# 5a. Typed confirmation, wrong answer. An accidental merge is unrecoverable, so
# the log must be empty of mutations, not merely missing a merge.
fx_reset
land_view "$WORK_BRANCH" OPEN '[{"name":"openbuilder:approved"}]'
land_plan_md
land_state_json
fx_ok gh.api-matching-refs
run_ob_in 'yes' land "$REPO" "$PR"
assert_eq 1 "$RC" 'land: refuses when the typed confirmation does not match'
assert_contains "confirmation did not match" "$OUT" \
    'land: the wrong-confirmation refusal says the confirmation did not match'
assert_contains 'nothing was merged and nothing was deleted' "$OUT" \
    'land: the wrong-confirmation refusal states that nothing happened'
assert_eq 0 "$(log_count 'gh pr merge')" \
    'land: a wrong confirmation makes no pr merge call'
assert_eq 0 "$(log_count 'gh api -X DELETE')" \
    'land: a wrong confirmation deletes no ref'
assert_no_mutation 'land: wrong-confirmation refusal makes no mutating call'

# 5b. Typed confirmation, exact phrase: one squash merge and the expected
# deletions, no more.
fx_reset
land_view "$WORK_BRANCH" OPEN '[{"name":"openbuilder:approved"}]'
land_plan_md
land_state_json
fx_ok gh.api-matching-refs
fx_ok gh.pr-merge
fx_ok gh.api-delete
run_ob_in "land $SLUG" land "$REPO" "$PR"
assert_eq 0 "$RC" 'land: the exact confirmation phrase lands the pull request'
assert_eq 1 "$(log_count "gh pr merge $PR --repo $REPO --squash --delete-branch")" \
    'land: exactly one squash merge, with --delete-branch'
assert_contains "gh api -X DELETE repos/$REPO/git/refs/heads/$PLAN_BRANCH" "$(log_read)" \
    'land: the plan branch is deleted'
assert_contains "gh api -X DELETE repos/$REPO/git/refs/heads/$DESIGN" "$(log_read)" \
    'land: the design branch is deleted when the epic has no unlanded slugs'
assert_eq 2 "$(log_count 'gh api -X DELETE')" \
    'land: exactly two refs are deleted (the head branch goes with the merge)'
assert_contains "landed $REPO#$PR :: $SLUG" "$OUT" \
    'land: the happy path reports what it landed'

# ===========================================================================
# review --watch — label logic
# ===========================================================================

# The design branch clone is what review --watch fetches into.
world_new
# ob_review_watch reads $OPENBUILDER_MAX_ATTEMPTS with `set -u` on, so it must
# be set for the loop to run at all. The unset case is the TODO at the end.
export OPENBUILDER_MAX_ATTEMPTS=6

review_fixtures() { # <label-line-1> [<label-line-2> ...]
    local i=1 l
    for l in "$@"; do
        fx_line "gh.pr-view-labels.$i" "$l"
        i=$((i + 1))
    done
}

# 1. blocked -> a human is required, and no reviewer session is started.
fx_reset
review_fixtures 'openbuilder:blocked'
fx_line gh.pr-view-comments 'the runner gave up in round 3'
run_ob review --watch "$REPO" "$PR"
assert_eq 4 "$RC" 'review --watch: a blocked pull request exits 4'
assert_contains "is blocked; a human is required" "$OUT" \
    'review --watch: the blocked refusal says a human is required'
assert_no_mutation 'review --watch: a blocked pull request starts no reviewer session'

# 2. approved -> exit 0, print the land line, review nothing.
fx_reset
review_fixtures 'openbuilder:approved'
run_ob review --watch "$REPO" "$PR"
assert_eq 0 "$RC" 'review --watch: an approved pull request exits 0'
assert_contains "approved. land it with: openbuilder land $REPO $PR" "$OUT" \
    'review --watch: an approved pull request prints the land it with: line'
assert_no_mutation 'review --watch: an approved pull request starts no reviewer session'

# 3. in-progress / changes-requested -> wait, do not review.
fx_reset
review_fixtures 'openbuilder:in-progress' 'openbuilder:changes-requested' 'openbuilder:blocked'
fx_line gh.pr-view-comments 'still blocked'
run_ob review --watch "$REPO" "$PR"
assert_eq 4 "$RC" 'review --watch: waits through in-progress and changes-requested'
assert_eq 2 "$(log_count 'sleep 60')" \
    'review --watch: in-progress and changes-requested each cost one wait, not a review'
assert_no_mutation 'review --watch: the instance owns in-progress/changes-requested — no session'

# 4. awaiting-review at a head sha already in the marker -> no second round.
fx_reset
mkdir -p "$REVIEW_DIR"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$MARKER"
review_fixtures 'openbuilder:awaiting-review' 'openbuilder:approved'
fx_line gh.pr-view-headRefOid 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fx_line gh.pr-view-headRefName "$WORK_BRANCH"
run_ob review --watch "$REPO" "$PR"
assert_eq 0 "$RC" 'review --watch: an already-reviewed head still reaches the approved verdict'
assert_contains 'already reviewed' "$OUT" \
    'review --watch: an already-reviewed head sha is reported as such'
assert_no_mutation 'review --watch: an already-reviewed head sha costs no second reviewer round'
assert_eq '' "$(cd "$CACHE_DIR/openbuilder" && find . -name '*.ndjson' | sort | tr '\n' ' ')" \
    'review --watch: an already-reviewed head sha writes no transcript'

# 5. awaiting-review at a new head sha -> exactly one round, marker updated, and
# the transcript at the path plan-workflow-06-automerge condition 2 reads.
fx_reset
rm -rf "$REVIEW_DIR"
mkdir -p "$REVIEW_DIR"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$MARKER"
review_fixtures 'openbuilder:awaiting-review' 'openbuilder:approved'
fx_line gh.pr-view-headRefOid 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
fx_line gh.pr-view-headRefName "$WORK_BRANCH"
fx_line omp.run '{"type":"result","subtype":"success"}'
run_ob review --watch "$REPO" "$PR"
assert_eq 0 "$RC" 'review --watch: a new head sha is reviewed and then lands on the verdict'
assert_eq 1 "$(log_count 'omp --cwd')" \
    'review --watch: a new head sha costs exactly one reviewer round'
assert_eq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$(cat "$MARKER")" \
    'review --watch: the marker is updated to the reviewed head sha'
assert_eq './review/obtest__widgets__42.round-01.ndjson ' \
    "$(cd "$CACHE_DIR/openbuilder" && find . -name '*.ndjson' | sort | tr '\n' ' ')" \
    'review --watch: the transcript is $OB_CACHE_DIR/review/<repo-key>__<pr>.round-01.ndjson'
assert_contains '{"type":"result","subtype":"success"}' "$(cat "$REVIEW_DIR/${KEY}__$PR.round-01.ndjson")" \
    'review --watch: the transcript holds the reviewer run output'

# 6. OPENBUILDER_MAX_ATTEMPTS=1 and a second new head sha -> exit 5.
fx_reset
rm -rf "$REVIEW_DIR"
export OPENBUILDER_MAX_ATTEMPTS=1
review_fixtures 'openbuilder:awaiting-review' 'openbuilder:awaiting-review'
fx_line gh.pr-view-headRefOid.1 'cccccccccccccccccccccccccccccccccccccccc'
fx_line gh.pr-view-headRefOid.2 'dddddddddddddddddddddddddddddddddddddddd'
fx_line gh.pr-view-headRefName "$WORK_BRANCH"
fx_line omp.run '{"type":"result","subtype":"success"}'
run_ob review --watch "$REPO" "$PR"
assert_eq 5 "$RC" 'review --watch: exhausting OPENBUILDER_MAX_ATTEMPTS exits 5'
assert_contains "reached 1 (OPENBUILDER_MAX_ATTEMPTS) without a verdict; a human is required" "$OUT" \
    'review --watch: the exhausted-rounds refusal says a human is required'
assert_eq 1 "$(log_count 'omp --cwd')" \
    'review --watch: the round cap is enforced before the extra reviewer round, not after'
export OPENBUILDER_MAX_ATTEMPTS=6

# ===========================================================================
# Everything below this line is expected to fail: `todo` is file-scoped, so it
# must come last.
#
# ob_review_watch expands $OPENBUILDER_MAX_ATTEMPTS unquoted-unset under
# `set -u` (`rounds_max=${OPENBUILDER_MAX_ATTEMPTS//[^0-9]/}`), so the
# documented default of 6 is unreachable: with the variable unset the command
# aborts with "unbound variable" after starting the instance and fetching the
# clone. The fix is one line, `${OPENBUILDER_MAX_ATTEMPTS:-}`; this asserts the
# contract, not the crash, so it flips to a failure the day it lands.
# ===========================================================================

todo 'PR #8: ob_review_watch reads $OPENBUILDER_MAX_ATTEMPTS under set -u, so the documented default of 6 never applies'
fx_reset
unset OPENBUILDER_MAX_ATTEMPTS
review_fixtures 'openbuilder:approved'
run_ob review --watch "$REPO" "$PR"
assert_eq 0 "$RC" \
    'review --watch: runs with OPENBUILDER_MAX_ATTEMPTS unset, defaulting to 6 rounds'
assert_contains "approved. land it with: openbuilder land $REPO $PR" "$OUT" \
    'review --watch: still reports the approved verdict with OPENBUILDER_MAX_ATTEMPTS unset'
