# Ignore scoping

An ignore rule lives next to what it ignores.

## The rule

- A directory whose contents are ignored carries its own `.gitignore`.
  `.harnx/.gitignore` names the two files that directory produces;
  `.worktrees/.gitignore` ignores everything beneath it except itself.
- The root `.gitignore` carries only what has no directory of its own: tool
  caches, editor droppings, and files matched by SHAPE rather than by location,
  such as `*.pem`.
- A rule is never written in two places. If a directory's `.gitignore` covers
  something, the root file does not repeat it.

## Why co-located and not one root file

A single root `.gitignore` is the obvious design and it fails in a specific
way: the rule and the thing it governs drift apart.

- **Deleting the directory leaves the rule behind.** The entry stays in the
  root file forever, matching nothing, and nobody dares remove it because
  nobody can tell what it was for.
- **Moving the directory silently stops the ignoring.** The path in the root
  file is now wrong, the files it protected start showing up as untracked, and
  the first person to notice adds them.
- **Reading the rule means reading a file somewhere else.** Somebody working in
  `.harnx/` sees an untracked file and has to go to the root to find out
  whether that is expected.

Co-locating fixes all three by construction: the rule moves with the
directory, dies with it, and is visible from inside it.

## The root file is this policy's own first case

The root `.gitignore` is not an exception to the rule. It is the scope that
owns what genuinely belongs to no directory:

- caches and build output that any directory might produce;
- editor and operating-system files, which appear anywhere;
- secret-shaped files (`*.pem`, `*.key`, `.env`), matched by shape precisely
  because the whole point is to catch one wherever it lands.

That last group is the earlier of two lines of defence, not the only one.
`gitleaks` scans the history as a required check. The ignore entry stops the
accident; the scanner catches what got past it.
