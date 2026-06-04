# E2E Smoke Test (manual — uses real cursor-agent + Composer)

Prereqs: `cursor-agent status` shows logged in.

## Setup
```bash
tmp=$(mktemp -d)
cd "$tmp"
git init -q && git commit -q --allow-empty -m "init"
printf 'Create a file calc.py with a function add(a, b) that returns a+b. Then create test_calc.py with a pytest test asserting add(2,3)==5.\n' > task.md
```

## 1. Happy path (Composer implements, verify passes)
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/cc-delegate.sh" \
  --task-file "$tmp/task.md" \
  --verify-cmd "python -m pytest -q"
```
Expect: stdout is one JSON line with `"status":"DONE"`, `"verified":true`,
`"attempts":0`. `calc.py` and `test_calc.py` now exist; `pytest` passes.

## 2. Resume fix-loop (force one failure)
```bash
# A verify command that fails the first time, passes after the file is corrected.
printf 'Create greet.py with greet() returning the string "hi".\n' > task2.md
bash "$CLAUDE_PLUGIN_ROOT/scripts/cc-delegate.sh" \
  --task-file "$tmp/task2.md" \
  --verify-cmd 'python -c "import greet; assert greet.greet()==\"hi\""' \
  --max-retries 3
```
Expect: `"status":"DONE"`, `"verified":true`. If Composer's first attempt is
already correct, `attempts` may be 0 — that's fine; the loop is exercised by test 3.

## 3. BLOCKED path (impossible verify)
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/cc-delegate.sh" \
  --task-file "$tmp/task.md" \
  --verify-cmd 'exit 1' \
  --max-retries 2
```
Expect: `"status":"BLOCKED"`, `"verified":false`, `"attempts":2`, exit code 1.

## 4. Preflight failure (logged out) — optional
Temporarily move auth or run in an environment without login; confirm
`/cursor-implement-plans` stops at preflight with a clear message.

## Cleanup
```bash
rm -rf "$tmp"
```
