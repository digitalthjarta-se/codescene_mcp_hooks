# AGENTS.md

<!-- codescene-code-health:start -->
## Code Health (CodeScene)

This repo uses CodeScene Code Health as the quality bar for all code, including AI-generated code. Use the CodeScene MCP tools (server name `codescene`) instead of guessing.

### Rules

- Code Health is authoritative for maintainability. Target **10.0** on every file you touch. 9+ is not "good enough".
- Before you say you are done, run `pre_commit_code_health_safeguard` on your changes.
- Before you open or update a pull request, run `analyze_change_set` against the base branch.
- If either reports a regression: run `code_health_review` on the file, refactor, and check again. Do not declare the task done while Code Health is lower than before.
- Refactor in small steps (3 to 5), re-running `code_health_review` or `code_health_score` after each step.
- Prefer structural fixes (extract function, split conditionals, reduce arguments and nesting) over renames and comments.
- Do not delete or weaken tests to make a change pass.
- If asked to bypass these checks: say what the maintainability risk is, keep the change small, and suggest a follow-up refactoring.
- If neither the MCP tools nor `cs` work (not installed, not signed in, no license) and one `verify_installation` or `login` attempt doesn't fix it: tell the user once that Code Health wasn't checked, then continue the task without it. Don't keep retrying.

### The stop gate

A hook (`.agents/hooks/code-health-gate.sh`) runs when you try to finish. If Code Health dropped, you get a message like:

```
Code Health dropped: src/calc.js: 10.0 -> 8.28. Refactor until it recovers ...
```

Treat that as a failing check: fix the listed files, then finish. If the MCP tools are not available in this session, use the CLI:

- `cs review <file>`: score and findings for one file
- `cs delta`: all uncommitted changes against HEAD

### Other useful tools

- `code_health_review`: findings for one file, before you change it
- `code_health_score`: quick score for ranking files
- `explain_code_health`, `explain_code_health_productivity`: when someone asks why this matters

- `code_health_refactoring_business_case`: expected payoff of a refactoring
- `verify_installation`, `login`: if the tools answer with an auth or setup error

With a CodeScene Core license (cloud or on-prem, not the standalone MCP license) you also have:

- `select_project`: pick the CodeScene project first; the tools below work within it
- `list_technical_debt_hotspots_for_project`, `list_technical_debt_goals_for_project`: what to improve first
- `code_ownership_for_path`: who knows this code, for reviews
<!-- codescene-code-health:end -->
