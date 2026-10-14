# .github/ (AGENTS.md)

`workflows/ci.yml` builds and tests this repository with the shared `ox-setup` action and
calls the `obj-magic` reusable workflow from `infra`.

- The pin list must match the org dependencies in `dune-project`; add a pin in the same commit
  as a new org dependency.
- Keep the `concurrency` block.
- Check a run with one `gh run list --limit 1`, and at most one `gh run watch <id> --exit-status`.
