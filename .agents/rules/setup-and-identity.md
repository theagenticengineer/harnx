# Setup and author identity

How to bring a clone of this repository to a working state, and the one piece
of configuration that is deliberately not optional.

After cloning:

```sh
mise trust
mise install
mise exec -- pre-commit install
mise exec -- pre-commit install --hook-type commit-msg
mise exec -- pre-commit install --hook-type post-checkout
mise exec -- pre-commit install --hook-type pre-push
mise exec -- pre-commit install --hook-type pre-merge-commit
```

Those five commands are a FALLBACK, not the primary path. `mise install` runs
`scripts/mise/setup-hooks.sh` from its `postinstall` hook and installs all five
stages for you; they are written out here for the case where somebody needs to
repair the hooks without a full install.

Then fill `.harnx/instance-config.toml`. This is **not optional**: until
`identity_policy` names a real policy, the git-identity gate FAILS every
commit and fails in CI. A floor that ships with a check switched off, and
says nothing about it, verifies nothing while looking like it does, so the
repo refuses to work until a human states the policy. The three states are:

- `"CHANGE_ME"`: unarmed. Every commit and every CI run fails. This is the
  shipped state.
- `"public"`: any author email is accepted, for a project taking outside
  contributions. A non-empty `git config user.name` and `user.email` are
  still required.
- `"private"`: only authors matching `allowed_authors` may commit. Each entry
  is either a bare domain (`acme.org`, any address on it) or a full address
  (`contractor@gmail.com`, only itself).

Under **both** armed policies the gate also rejects an address that cannot
belong to a real person:

- a malformed shape, meaning anything without exactly one `@` with text on
  both sides;
- a dotless domain. ICANN prohibits them and SMTP cannot route one, so a
  container's `root@<container-id>` never reaches anybody;
- the reserved namespaces of RFC 2606, RFC 6761, RFC 8375, and ICANN's
  `.internal`;
- `.local`, which is RFC 6762's link-local namespace and also what git itself
  generates as `username@hostname` when no identity is set.

`@users.noreply.github.com` is deliberately allowed. It looks like a
placeholder and is in fact a real, owned, per-account GitHub address, so
blocking it would lock out contributors doing exactly the right thing.

`denied_authors` in the same file adds per-repo rejections on top, using the
same matching rule. A site-local canary identity belongs there rather than in
the shipped gate, because it means nothing outside the shop that invented it
and usually sits on a domain that shop does not own.

When a contributor's email is rejected under `"private"`, the fix is for them
to reconfigure their own git identity (`git config user.email`), not to widen
the list. Widening it is a policy change, and the file is CODEOWNERS-protected
so that it takes a human review.
