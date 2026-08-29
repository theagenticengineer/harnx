# Git discipline

Every rule below is enforced by a hook, a CI check, or both. None of them is a
convention you are trusted to remember.

- Every change lands through a pull request into the branch below it in the
  stack. The protected default branch rejects a direct push.
- That default branch is not always `main`. While an epic needs a trust anchor
  carrying infrastructure `main` does not have yet, the default branch points
  at that anchor and `main` is left untouched.
- Read the default branch live rather than assuming it:
  `gh api repos/{owner}/{repo} -q .default_branch`.
- Never use `git commit --no-verify`, `git push --no-verify`, or otherwise
  bypass a hook. A hook failure is real signal to fix, not to route around.
- One commit per push, with one exception: this repo's own first commit
  (genesis), which by necessity lands whole. Every commit after it follows
  the cadence: commit, push, wait for CI green, next commit. CI re-checks
  every push from scratch, so a bypassed local hook is still caught remotely.
- A commit header must match `type(#N): title` (for example
  `fix(#6): a valid enough title`), where `N` matches the current branch's
  own issue number. `type` is one of `feat`, `fix`, `docs`, `refactor`,
  `test`, `chore`, `build`, `ci`, `perf`, `revert`.
- `git revert`'s own default commit message (`Revert "<original subject>"`)
  never passes validation as-is: it carries no `(#N):` issue scope. Edit the
  message into the same `revert(#N): title` shape every other commit uses
  before it can land.
- A branch must match `type-N-title` (for example `fix-6-title`), and must be
  checked out inside a git worktree, never in the primary clone, which always
  stays on `main`.
- The hooks enforcing that exempt the literal name `main` only. A trust-anchor
  branch serving as the default is therefore worked on through git plumbing or
  the API, never through a local checkout in the primary clone.
- The default branch is squash-merge-only, so a PR's title becomes the squash commit's
  subject: the `pr-title` CI check holds it to the exact same `type(#N):
  title` format and issue-number cross-check as a commit header.
- The PR body must carry `Closes #N` for the issue the branch delivers, N
  matching the branch's own issue number: the `pr-body` CI check enforces it.
