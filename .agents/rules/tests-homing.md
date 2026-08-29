# Paired-Test Homing

`scripts/tests/*.bash` is the sole paired-test home. The `shell-tests` CI job
(`.github/workflows/ci.yml`) discovers tests by globbing exactly that path
(`scripts/mise/test.sh`):

```sh
for t in scripts/tests/*.bash; do
  bash "$t" || status=1
done
```

A test homed anywhere else (a different directory, a different extension,
nested one level deeper) is never discovered and silently never runs. CI goes
green with no signal that the test exists at all.

## Rule

- Every paired test for a shell script or gate lands directly in
  `scripts/tests/`, as a `.bash` file, in the same commit as the code it
  tests (this repo's one-commit-per-push cadence, see AGENTS.md's "Git
  discipline" section).
- Match the naming convention already in use: the test file name mirrors the
  script under test, minus the script's own subdirectory and extension
  (`scripts/git-discipline/validate-branch-name.sh` ->
  `scripts/tests/validate-branch-name.bash`;
  `scripts/git-discipline/check-git-identity.sh` ->
  `scripts/tests/check-git-identity.bash`).
- Before trusting a new test, confirm it actually runs:
  `bash scripts/tests/<name>.bash` locally, and check the glob would match it
  (`scripts/tests/*.bash`, no subdirectory).
