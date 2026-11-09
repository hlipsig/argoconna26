#!/usr/bin/env bats
# Tests for scripts/configure-fork.sh (Task 6.7a). Offline: it only edits files in a copy of the repo.

load helpers

OLD_SLUG="argo-multiverse-labs/argoconna26"
OLD_LOGIN="argoconna26-agent[bot]"
OLD_TEAM="@argo-multiverse-labs/promotion-board"
NEW_SLUG="someone/my-argo-demo"
NEW_LOGIN="my-demo-agent[bot]"
NEW_TEAM="@someone/review-board"

setup() {
  WORK="$BATS_TEST_TMPDIR/fork"
  mkdir -p "$WORK"
  # A copy of the working tree (tracked and new files, so an unstaged script is included).
  ( cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - ) | tar -xf - -C "$WORK"
  OLD_SLUG="$(sed -n 's/^REPO_SLUG=//p' "$WORK/demo.env")"
  OLD_LOGIN="$(sed -n 's/^BOT_LOGIN=//p' "$WORK/demo.env")"
  OLD_TEAM="$(sed -n 's/^PROMOTION_TEAM=//p' "$WORK/demo.env")"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@example.invalid
  git -C "$WORK" config user.name t
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m copy
}

configure() { "$WORK/scripts/configure-fork.sh" --root "$WORK" "$@"; }

@test "configure-fork rewrites every repoURL, CODEOWNERS team, agent login and demo.env names" {
  run configure --repo-slug "$NEW_SLUG" --bot-login "$NEW_LOGIN" --promotion-team "$NEW_TEAM"
  [ "$status" -eq 0 ]
  # The deployed-config surfaces no longer name the upstream repo, team or login anywhere.
  run git -C "$WORK" grep -nF -e "argo-multiverse-labs" -e "argoconna26-agent" -- gitops .github policy/data bridge/deploy demo.env
  [ "$status" -eq 1 ]
  grep -q "^REPO_SLUG=$NEW_SLUG\$" "$WORK/demo.env"
  grep -qF "BOT_LOGIN=$NEW_LOGIN" "$WORK/demo.env"
  grep -q "^PROMOTION_TEAM=$NEW_TEAM\$" "$WORK/demo.env"
  # Every Application repoURL, and only those lines changed in gitops/.
  run git -C "$WORK" grep -h "repoURL:" -- gitops
  [ "$status" -eq 0 ]
  [ -z "$(grep -v "https://github.com/$NEW_SLUG.git" <<<"$output")" ]
  grep -qF "agent_login: $NEW_LOGIN" "$WORK/policy/data/agent.yaml"
  grep -Eq "^/aiops/autonomy\.yaml +$NEW_TEAM\$" "$WORK/.github/CODEOWNERS"
  grep -Eq "^/policy/ +$NEW_TEAM\$" "$WORK/.github/CODEOWNERS"
  grep -Eq "^/\.github/ +$NEW_TEAM\$" "$WORK/.github/CODEOWNERS"
  # The bridge Deployment's env, in its own quoting.
  grep -qF "{name: REPO_SLUG, value: $NEW_SLUG}" "$WORK/bridge/deploy/deployment.yaml"
  grep -qF "{name: BOT_LOGIN, value: \"$NEW_LOGIN\"}" "$WORK/bridge/deploy/deployment.yaml"
  # Comments in CODEOWNERS and the other lines are untouched, and the result is consistent.
  grep -q '^# Changes to the agent' "$WORK/.github/CODEOWNERS"
  run "$WORK/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "consistency: OK" ]
}

@test "configure-fork is idempotent" {
  configure --repo-slug "$NEW_SLUG" --bot-login "$NEW_LOGIN" --promotion-team "$NEW_TEAM"
  git -C "$WORK" add -A; git -C "$WORK" commit -q -m first
  run configure --repo-slug "$NEW_SLUG" --bot-login "$NEW_LOGIN" --promotion-team "$NEW_TEAM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already configured"* ]]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

@test "configure-fork can be run again with other names, and back to upstream" {
  configure --repo-slug "$NEW_SLUG" --bot-login "$NEW_LOGIN" --promotion-team "$NEW_TEAM"
  configure --repo-slug "$OLD_SLUG" --bot-login "$OLD_LOGIN" --promotion-team "$OLD_TEAM"
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

@test "configure-fork keeps a value that is not given" {
  run configure --repo-slug "$NEW_SLUG"
  [ "$status" -eq 0 ]
  grep -qF "BOT_LOGIN=$OLD_LOGIN" "$WORK/demo.env"
  grep -q "^PROMOTION_TEAM=$OLD_TEAM\$" "$WORK/demo.env"
  grep -qF "agent_login: $OLD_LOGIN" "$WORK/policy/data/agent.yaml"
  run "$WORK/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
}

@test "configure-fork rejects malformed names before changing any file" {
  run configure --repo-slug "not-a-slug"
  [ "$status" -ne 0 ]
  run configure --bot-login "no-bot-suffix"
  [ "$status" -ne 0 ]
  run configure --promotion-team "someone/board"
  [ "$status" -ne 0 ]
  run configure
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

@test "configure-fork rewrites the two-line env form in the bridge Deployment" {
  f="$WORK/bridge/deploy/deployment.yaml"
  sed -i -e 's#{name: REPO_SLUG, value: [^}]*}#name: REPO_SLUG\n              value: x/y#' \
         -e 's#{name: BOT_LOGIN, value: [^}]*}#name: BOT_LOGIN\n              value: "z[bot]"#' "$f"
  run configure --repo-slug "$NEW_SLUG" --bot-login "$NEW_LOGIN"
  [ "$status" -eq 0 ]
  grep -qE "^ +value: $NEW_SLUG\$" "$f"
  grep -qF "value: \"$NEW_LOGIN\"" "$f"
}

@test "make configure-fork passes the three names through" {
  run make -C "$WORK" configure-fork REPO_SLUG="$NEW_SLUG" BOT_LOGIN="$NEW_LOGIN" PROMOTION_TEAM="$NEW_TEAM"
  [ "$status" -eq 0 ]
  grep -q "^REPO_SLUG=$NEW_SLUG\$" "$WORK/demo.env"
  run make -C "$WORK" configure-fork
  [ "$status" -ne 0 ]
}
