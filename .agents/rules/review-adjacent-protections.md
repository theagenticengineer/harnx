# Review-adjacent protections

Two branch-protection settings that exist to keep the required checks from
being weakened by the same pull request they are meant to check.

`.github/CODEOWNERS` requires a code-owner review, never satisfiable by the
pull request author's own approval, for any change to a file that defines or
executes what a required check enforces:

- everything under `scripts/`, which is every gate this floor executes;
- `.github/workflows/` and `.github/CODEOWNERS` itself, so the list cannot be
  edited without a review either;
- the governance documents: `AGENTS.md` and `.agents/rules/`. They execute
  nothing and gate nothing, so a silent edit turns no check green; it rewrites
  what a contributor or an agent believes the rules are;
- `.harnx/instance-config.toml`, which arms the identity gate;
- **every linter's config, not only the two that existed when this list was
  first written**: `.pre-commit-config.yaml`, `mise.toml`, `.yamllint.yaml`,
  `.vale.ini`, `styles/`, `.gitleaks.toml`, `.markdownlint.yaml`,
  `.markdownlintignore`, `.taplo.toml`, `.shellcheckrc` and `lychee.toml`.

That last group grew, and the way it grew is the point. `.yamllint.yaml` and
`.vale.ini` were listed because they were the configs that existed; five more
arrived later, gating five more required checks, and nothing noticed they were
unprotected. CODEOWNERS has no way to say "and any future one".

`scripts/tests/codeowners-coverage.bash` closes that: it derives the list from
the configs the hooks and workflows actually name, plus the ignore files they
discover without being told, and fails when one of them is unprotected. This
list is prose and can go stale; that test cannot.

`require_code_owner_reviews: true` is set by
`scripts/configure-protection.sh`.

This is the tamper-evidence measure for every required check. An edit that
silently weakened one must pass a human review of that exact diff before it can
merge: making `check-resolved.sh` always exit 0, say, or dropping a hook entry
from `.pre-commit-config.yaml`.

CODEOWNERS gates the MERGE of such an edit, not its EXECUTION, which is why it
closes neither credential-exposure pattern on its own. The split pipeline and
the environment do that.

Branch protection also sets `dismiss_stale_reviews: true`. Every new push to a
pull request dismisses all prior approvals, not only pushes that touch a
CODEOWNERS-listed path, because GitHub has no path-scoped version of this
setting.

Without it, a contributor could get a protected path approved, then push a
different change to that same path and merge without a fresh review of the
actual final diff, defeating the code-owner requirement above.

The cost is real: every push needs a fresh approval, on top of the
one-commit-per-push cadence this floor already establishes.
