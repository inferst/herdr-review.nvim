# Issue tracker: GitHub

Issues and PRDs for this repository live as GitHub issues. Use the `gh` CLI
for all operations and infer the repository from `git remote -v`.

## Conventions

- Create an issue with `gh issue create --title "..." --body "..."`.
- Read an issue and its discussion with `gh issue view <number> --comments`.
- List issues with `gh issue list` and suitable state and label filters.
- Comment with `gh issue comment <number> --body "..."`.
- Apply or remove labels with `gh issue edit`.
- Close an issue with `gh issue close <number> --comment "..."`.

Pull requests are not a triage request surface for this repository.

## Publishing

When a skill says to publish work to the issue tracker, create a GitHub issue.
Apply the `ready-for-agent` label to agent-ready work unless instructed
otherwise.

Publish dependent issues after their blockers so their bodies can reference
real issue numbers. Use GitHub native issue dependencies when available;
otherwise include a `Blocked by: #<number>` entry in the issue body.
