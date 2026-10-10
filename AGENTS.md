# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Quick Reference

See the Quick Reference in Beads Issue Tracker below (`bd update <id> --claim` claims atomically). Also available: `bd dolt push` (push beads data to remote).

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations. `cp`, `mv`, and `rm` may be aliased to `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Release Archives

Before creating, exporting, or uploading an Xcode Organizer / App Store Connect archive, bump the app version/build metadata — never do so from an unchanged version. Verify the final archive/package reports the bumped version and build number before handing it off.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## Build & Test

_Add your build and test commands here_

```bash
# Example:
# npm install
# npm test
```

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_

## Spec: use Giulio's Specify, not GitHub's

Skim's product spec is `skim.spec/` (one file per area under `skim.spec/areas/`). Maintain it with
Giulio's Specify, https://github.com/gm2211/specify, and never with GitHub's Spec Kit `specify` CLI
(`uvx specify-cli`, `specify init`, `.specify/`, `specs/NNN-*/spec.md`). Both tools install an
executable named `specify`, so never run a bare `specify` from PATH.

Specify CLI: scripts/specify.sh

Wherever the managed block below says `specify`, run `scripts/specify.sh`. It uses `$SPECIFY_CLI`,
then `~/projects/specify/specify`, then `../specify/specify`, and otherwise clones gm2211/specify
into `~/.cache/skim/specify`. `scripts/specify.sh view --spec skim.spec` opens the spec in a browser.
Keep the spec current and curated whenever a decision lands or a feature ships, changes, or is
removed; do not keep a second feature list elsewhere.

<!-- specify:begin:spec-workflow -->
## Maintain specs as you work

Canonical spec: "skim.spec". Run commands from "." relative to this file.

- Read relevant spec areas and global constraints before editing. Use `specify spec guide` for structure and its capture, review, and reconcile workflow.
- Record explicit user decisions directly in the spec, even when no code changes. Keep stable behavior IDs; store exact quotations in source.text and a reference when available. Label proposals and assumptions in prose; never promote guesses into requirements.
- Keep one feature per area, short behavior descriptions, and detail in details/prose. Use `specify spec split --spec 'skim.spec'` for oversized single-file specs.
- Update specs when intent changes. Never rewrite requirements to excuse incomplete implementation. Report unmet requirements in the handoff and issue tracker.
- Before implementation, review new intent against relevant behaviors, global constraints, and existing plans/tasks. Cite conflicting IDs and sources; resolve authorized changes, surface unresolved decisions, and continue independent work. This is agent review, not a semantic check performed by Specify.
- After implementation, reconcile affected and potentially regressed behavior IDs against current code and actual smoke/regression results, including the original bug reproduction. Report each as satisfied, gap, or unverified with evidence and revision. Add corrective work to the existing tracker, implement authorized fixes, and repeat; never use checked tasks or passing formal models as application proof.
- Keep the selected spec authoritative. Plans/tasks reference behavior IDs; do not create duplicate requirements or a separate evidence store. Put command/results and blockers in the existing PR or task tracker. Do not declare completion with unmet requirements or missing required verification.
- Before finishing, run `specify spec check --spec 'skim.spec' --base BASE`. Use the task start commit or PR base. If intent is unchanged, pass `--reason 'why existing requirements still cover this change'` instead of making a token spec edit. Include that explanation in the PR.
- Run project tests separately. This check enforces spec lint and a recorded review reason or source change, not semantic correctness or execution proof.
- For properties linked from behaviors, run `specify formal check --spec 'skim.spec'` with caller-installed Quint or Lean. A passing model check does not establish that the model captures prose or that the application satisfies it.
<!-- specify:end:spec-workflow -->
