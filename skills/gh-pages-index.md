# gh-pages Index

## Worktree hygiene

The index lives on the `gh-pages` branch, managed via a git worktree at `/tmp/jorgehub-pages`.

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

## update-index.py

Located at `scripts/update-index.py`. Regenerates `index/static` on the gh-pages branch.
Run with `--validate` to check JSON without writing.
