# gh-pages Index

## When to Use
- Running or debugging `update-index`, gh-pages worktree, or index shape
- Diagnosing why an app is missing from the Flatpak remote

## When NOT to Use
- Build pipeline mechanics → `skills/pipeline.md`
- App-specific build quirks → `skills/app-gotchas.md`

## Worktree hygiene

The index lives on the `gh-pages` branch, managed via a git worktree at `/tmp/<repo-name>-pages`.

**Always fetch before committing.** Before any `git add` in the worktree:

```bash
git fetch origin gh-pages && git rebase origin/gh-pages
```

Committing after a stash-pop onto a diverged remote causes git to treat JSON as plain text
and merge both versions — the result is duplicate entries in `index/static` JSON files.
Always manually verify dedup after any rebase of index/static changes.

**Session hygiene:** always commit or discard any pending gh-pages worktree changes before
ending a session. Never leave the worktree dirty or in a detached HEAD state.

## Updating the index

After `just build <app>` pushes to ghcr.io:

```bash
just update-index <app>
```

This runs `scripts/update-index.py` in the gh-pages worktree, commits, and pushes.

## Validating the index

```bash
just check-index   # validates index/static JSON from main branch (uses worktree internally)
```

**GOTCHA:** `--validate` does not use `--repo`. The `--repo` argument in `update-index.py`
must be declared as optional (not `required=True`) so `just check-index` (which calls
`--validate` without `--repo`) works. If argparse declares `--repo` as required
unconditionally, the `--validate` path hard-fails. Fixed in commit 542883b.

## update-index.py

Located at `scripts/update-index.py`. Regenerates `index/static` on the gh-pages branch.
Run with `--validate` to check JSON without writing.

## CI event filter (update-index.yml)

`update-index.yml` uses an allowlist to decide when to run:

```yaml
if: >-
  github.event.workflow_run.conclusion == 'success' &&
  (github.event.workflow_run.event == 'push' ||
   github.event.workflow_run.event == 'merge_group' ||
   github.event.workflow_run.event == 'workflow_dispatch')
```

**Why allowlist, not denylist:** The original guard was `event != 'pull_request'`.
GitHub's merge queue fires `workflow_run` with `event: 'merge_group'`, which
passed the denylist — but builds that only affect non-flatpak files (e.g., CI
workflow changes) also fire `event: 'push'` with no digest artifacts, causing
update-index to run but find nothing.

The allowlist explicitly permits only the three events that should update the index:
- `push` — direct pushes to main touching `flatpaks/**`
- `merge_group` — merge queue merges
- `workflow_dispatch` — manual test builds

**If ghostty/any app is missing from the remote after a merge:**
The build succeeded but update-index was skipped. Fix: trigger a fresh build
via `gh workflow run build.yml -f app=<app>` — this uses `workflow_dispatch`
which is in the allowlist.
