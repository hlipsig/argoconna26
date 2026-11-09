#!/usr/bin/env bats
# Tests for scripts/litellm.sh (curl and kubectl are stubs; nothing leaves the machine)

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  STATE="$BATS_TEST_TMPDIR/state"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$STATE"
  : > "$CALLS"
  # curl: a tiny LiteLLM. Credentials arrive through -K files and are never in argv.
  make_stub "$STUBS" curl 'echo "CURL: $*" >> "'"$CALLS"'"
    method=GET; cfg=""; url=""; body=""; outf=""
    while [ $# -gt 0 ]; do
      case "$1" in -X) method="$2"; shift 2 ;; -K) cfg="$2"; shift 2 ;; -d) body="$2"; shift 2 ;; -o) outf="$2"; shift 2 ;; -H|--max-time|-w) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
    done
    path="${url#*://*/}"; path="/${path#/}"
    [ -z "$cfg" ] || cp "$cfg" "'"$STATE"'/last-cfg" 2>/dev/null || true
    tok="$(sed -n "s/^header = \"Authorization: Bearer \(.*\)\"$/\1/p" "'"$STATE"'/last-cfg")"
    case "$method $path" in
      "GET /health/readiness") echo "{}" ;;
      "GET /key/info")
        grep -qx "$tok" "'"$STATE"'/valid" 2>/dev/null && echo "{\"info\":{\"max_budget\":30,\"spend\":1}}" || exit 22 ;;
      "GET /key/list"*)
        a="$(sed -n "s/.*key_alias=\([a-z]*\).*/\1/p" <<<"$path")"
        if grep -qx "$a" "'"$STATE"'/aliases" 2>/dev/null; then echo "{\"keys\":[{\"key_alias\":\"$a\"}]}"; else echo "{\"keys\":[]}"; fi ;;
      "POST /v1/chat/completions")
        # one line of STATE/chat per call: "<code> <body>"
        c=$(( $(cat "'"$STATE"'/chat-n" 2>/dev/null || echo 0) + 1 )); echo $c > "'"$STATE"'/chat-n"
        line="$(sed -n "${c}p" "'"$STATE"'/chat")"
        printf %s "${line#* }" > "${outf:-/dev/null}"; printf %s "${line%% *}" ;;
      "POST /key/delete") echo "$body" >> "'"$STATE"'/deleted"; echo "{}" ;;
      "POST /key/generate")
        echo "$body" >> "'"$STATE"'/generated"
        a="$(jq -r .key_alias <<<"$body")"
        n=$(( $(cat "'"$STATE"'/n" 2>/dev/null || echo 0) + 1 )); echo $n > "'"$STATE"'/n"
        echo "sk-$a-$n" >> "'"$STATE"'/valid"; echo "$a" >> "'"$STATE"'/aliases"
        echo "{\"key\":\"sk-$a-$n\"}" ;;
      *) echo "unexpected: $method $path" >&2; exit 22 ;;
    esac'
  make_stub "$STUBS" kubectl 'echo "ARGS: $*" >> "'"$CALLS"'"
    case "$*" in
      "config current-context") echo kind-argoconna26 ;;
      *"get namespace"*) ;;
      *"get secret holmes-llm"*"jsonpath"*) [ -f "'"$STATE"'/s-holmes" ] && base64 -w0 < "'"$STATE"'/s-holmes" || true ;;
      *"get secret judge-llm"*"jsonpath"*) [ -f "'"$STATE"'/s-judge" ] && base64 -w0 < "'"$STATE"'/s-judge" || true ;;
      *"get secret"*) echo "{\"metadata\":{}}" ;;
      *"create secret generic"*)
        d="$(grep -o -- "--from-file=/[^ ]*" <<<"$*" | cut -d= -f2-)"
        name="$(grep -o "generic [a-z-]*" <<<"$*" | cut -d" " -f2)"
        printf %s "$(cat "$d/OPENAI_API_KEY")" > "'"$STATE"'/next-$name"
        echo "apiVersion: v1"; echo "kind: Secret"; echo "name: $name" ;;
      *"apply"*"-f -"*) n="$(sed -n "s/^name: //p")"; mv "'"$STATE"'/next-$n" "'"$STATE"'/s-${n%-llm}"; echo applied ;;
    esac'
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  printf 'LITELLM_MASTER_KEY=sk-master-s3cret\nLLM_BUDGET_USD=50\n' > "$FIXTURE/.env"
  chmod 600 "$FIXTURE/.env"
}

run_keys() { ( cd "$FIXTURE" && "$REPO_ROOT/scripts/litellm.sh" keys ); }

@test "first run makes holmes (60 percent, rca) and judge (judge) and stores both" {
  run run_keys
  [ "$status" -eq 0 ]
  jq -se '[.[] | select(.key_alias=="holmes")][0].max_budget == 30' "$STATE/generated"
  [ "$(jq -sr '[.[] | select(.key_alias=="holmes")][0].models[0]' "$STATE/generated")" = "rca" ]
  [ "$(jq -sr '[.[] | select(.key_alias=="judge")][0].models[0]' "$STATE/generated")" = "judge" ]
  [ "$(cat "$STATE/s-holmes")" = "sk-holmes-1" ]
  [ "$(cat "$STATE/s-judge")" = "sk-judge-2" ]
}

@test "second run reuses keys the proxy accepts" {
  run_keys
  : > "$STATE/generated"
  run run_keys
  [ "$status" -eq 0 ]
  [ ! -s "$STATE/generated" ]
  [ "$(cat "$STATE/s-holmes")" = "sk-holmes-1" ]
}

@test "a stored key the proxy rejects is replaced after deleting its alias" {
  run_keys
  : > "$STATE/valid"
  run run_keys
  [ "$status" -eq 0 ]
  grep -q holmes "$STATE/deleted"
  [ "$(cat "$STATE/s-holmes")" = "sk-holmes-3" ]
}

@test "the master key and the minted keys never appear in curl or kubectl arguments" {
  run_keys
  ! grep -q "sk-master-s3cret" "$CALLS"
  ! grep -q "sk-holmes" "$CALLS"
  ! grep -q "sk-judge" "$CALLS"
}

@test "spend_total sums the exported files and the live spend" {
  mkdir -p "$BATS_TEST_TMPDIR/sp"
  echo '{"total":1.5}' > "$BATS_TEST_TMPDIR/sp/a.json"
  echo '{"total":2.25}' > "$BATS_TEST_TMPDIR/sp/b.json"
  run bash -c ". '$REPO_ROOT/scripts/litellm.sh'; spend_total '$BATS_TEST_TMPDIR/sp' 0.25"
  [ "$status" -eq 0 ]
  [ "$output" = "4.0000" ]
}

@test "spend_total with no files is the live spend" {
  run bash -c ". '$REPO_ROOT/scripts/litellm.sh'; spend_total '$BATS_TEST_TMPDIR/nope' 0.1"
  [ "$output" = "0.1000" ]
}

run_budget() { ( cd "$FIXTURE" && "$REPO_ROOT/scripts/litellm.sh" budget-check ); }

@test "budget-check passes on 200 then a budget_exceeded refusal, and deletes the key" {
  printf '%s\n' '200 {"choices":[]}' '400 {"error":{"type":"budget_exceeded","message":"Budget has been exceeded"}}' > "$STATE/chat"
  run run_budget
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused on call 2"* ]]
  grep -q budget-check "$STATE/deleted"
}

@test "budget-check fails when call 1 is not a 200" {
  printf '%s\n' '400 {"error":{"type":"invalid_request_error","message":"Invalid model name"}}' > "$STATE/chat"
  run run_budget
  [ "$status" -ne 0 ]
  [[ "$output" == *"call 1"* ]]
  grep -q budget-check "$STATE/deleted"
}

@test "budget-check fails on a later 4xx that is not a budget error" {
  printf '%s\n' '200 {}' '401 {"error":{"type":"auth_error","message":"Invalid key"}}' > "$STATE/chat"
  run run_budget
  [ "$status" -ne 0 ]
  [[ "$output" != *"refused on call"* ]]
  grep -q budget-check "$STATE/deleted"
}

@test "budget-check fails when every call succeeds" {
  printf '%s\n' '200 {}' '200 {}' '200 {}' '200 {}' > "$STATE/chat"
  run run_budget
  [ "$status" -ne 0 ]
  [[ "$output" == *"not enforced"* ]]
}

@test "ChatGPT keys have request limits without requiring a dollar budget" {
  printf 'LLM_PROVIDER=chatgpt\nLLM_BUDGET_USD=\n' >> "$FIXTURE/.env"
  run run_keys
  [ "$status" -eq 0 ]
  jq -se 'length == 2 and all(.[]; .max_budget == null and .rpm_limit == 10 and .tpm_limit == 100000)' "$STATE/generated"
}

@test "ChatGPT spend reports unavailable dollar accounting without network calls" {
  printf 'LLM_PROVIDER=chatgpt\nLLM_BUDGET_USD=\n' >> "$FIXTURE/.env"
  run bash -c 'cd "$1"; "$2/scripts/litellm.sh" spend' _ "$FIXTURE" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dollar spend and remaining quota are unavailable"* ]]
  ! grep -q "^CURL:" "$CALLS"
}

@test "ChatGPT dollar budget check refuses to claim budget enforcement" {
  printf 'LLM_PROVIDER=chatgpt\n' >> "$FIXTURE/.env"
  run bash -c 'cd "$1"; "$2/scripts/litellm.sh" budget-check' _ "$FIXTURE" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Dollar budget enforcement is unavailable"* ]]
  ! grep -q "^CURL:" "$CALLS"
}
