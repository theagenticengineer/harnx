#!/usr/bin/env bash
# Single source of truth for the conventional-commit type list and header
# regex, sourced by validate-commit-msg.sh AND validate-branch-name.sh so the
# allowed types can never drift between the two formats they gate.
#
# Title must be >=10 chars and must not end in whitespace: git log renders
# headers as plain text, and the trailing-whitespace hook enforces the same
# cleanliness everywhere else.
#
# Includes "revert": without it, there is no way to author a conventional,
# issue-scoped revert commit at all. This alone does not make git's own
# default `git revert` output pass validation: that default subject is
# `Revert "<original subject>"`, with no `(#N):` issue scope, so it always
# fails COMMIT_HEADER_RE regardless of the type whitelist. A revert must be
# authored (or the default message edited) into the same
# `revert(#N): title` shape every other commit uses; see AGENTS.md.
# shellcheck disable=SC2034  # consumed by the files that source this fragment
COMMIT_TYPES_RE='feat|fix|docs|refactor|test|chore|build|ci|perf|revert'
# shellcheck disable=SC2034  # consumed by the files that source this fragment
COMMIT_HEADER_RE="^(${COMMIT_TYPES_RE})\\(#[0-9]+\\): .{9,}[^[:space:]]\$"
