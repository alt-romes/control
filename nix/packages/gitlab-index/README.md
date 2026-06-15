# gitlab-index

A local, fuzzy-searchable index of a GitLab project's **issues and merge
requests** (and their comments). Source code is *not* fetched — only issues,
MRs, and notes.

Built for large instances (tested against `gitlab.haskell.org`, ~27k issues +
MRs). A Haskell binary shells out to the `glab` CLI for all API access, so
auth/host/token handling stays glab's job.

## Usage

```sh
# First run: full backfill. Subsequent runs only fetch changed items.
gitlab-index --project ghc/ghc sync

# Fetch notes more (or less) aggressively: N concurrent note requests (default 8).
gitlab-index --project ghc/ghc -j16 sync

# Fuzzy-search titles; preview pane (glow) shows the full thread.
gitlab-index --project ghc/ghc search

# Live ripgrep full-text search over titles, bodies AND comments.
gitlab-index --project ghc/ghc search --full
```

`--host` defaults to `gitlab.haskell.org`. `--project` can also come from
`$GITLAB_INDEX_PROJECT`. `ctrl-d`'s diff needs a local clone of the project:
point at one with `--repo DIR` or `$GITLAB_INDEX_REPO` (it fetches the MR head
ref and the target branch into private `refs/gitlab-index/*` refs, leaving your
own branches untouched). In `search`:

| key      | action                                             |
|----------|----------------------------------------------------|
| `ctrl-t` | toggle title ⇄ grep mode (live)                    |
| `enter`  | read the full item locally (glow's pager)          |
| `ctrl-v` | open the rendered item in `$EDITOR` (vim)          |
| `ctrl-d` | (MRs) open a vim [Fugitive](https://github.com/tpope/vim-fugitive) diff of the MR branch vs. its base |
| `ctrl-o` | open the item in the browser                       |
| `ctrl-r` | compose a comment in `$EDITOR` and post it via glab |
| `ctrl-s` | sync (fetch new/changed items), then reload the list  |

Two search modes, switchable live with **ctrl-t** (`--full` only picks the
starting one): *title* fuzzy-matches the displayed rows (via fzf), and *grep*
is a live [ripgrep](https://github.com/BurntSushi/ripgrep) search matching
anywhere in titles, descriptions and comments (regex, smart-case).

Each row is `#<iid>`/`!<iid>` (issue/MR), right-padded so columns line up, with
a compact state glyph: `○` open · `●` closed/merged.

Inline (diff-positioned) comments are labelled with their `` `path:line` `` so
it's clear what each comment refers to.

Previews are rendered with [glow](https://github.com/charmbracelet/glow).
`--style` sets glow's theme (`auto`/`light`/`dark`/…); in the fzf preview pane
glow can't probe the terminal background, so pass `--style light` or
`--style dark` if `auto` gives you an unreadable theme.

A zsh alias is provided: `ghc-index` = `gitlab-index --project ghc/ghc --style light --repo ~/ghc-dev/ghc`.

## How sync works

Items are listed ordered by `updated_at` with `updated_after=<watermark>`.
GitLab bumps an item's `updated_at` whenever it changes — *including when a
comment is added* — so re-fetching changed items (and re-pulling their notes)
keeps comments current. The watermark is checkpointed after every page, so an
interrupted backfill resumes where it left off. Items with zero comments skip
the notes request entirely. This is the cheapest "least aggressive" approach:
the only expensive run is the initial backfill.

Keyset pagination follows the `Link: rel="next"` header (avoids GitLab's
offset-pagination limits).

## On-disk layout

Under `$XDG_DATA_HOME/gitlab-index/<host>/<project>/` (override with
`--data-dir`):

```
items/issue/<iid>.json   raw issue object + its notes  (source of truth)
items/mr/<iid>.json      raw MR object + its notes
index.tsv                derived; what fzf reads (rebuild with `reindex`)
state.json               per-type updated_after watermarks
```

The raw JSON is kept verbatim, so the index/preview format can change and be
regenerated with `gitlab-index reindex` without re-downloading anything.

## Concurrency & resilience

- Pagination is sequential (it follows the `Link: rel="next"` header), but the
  per-item notes fetches within each page run concurrently — `-j/--jobs`
  controls how many (default 8). The binary uses the threaded RTS so these
  actually overlap.
- Every `glab` call retries with exponential backoff (1s, 2s, 4s, …) on
  *transient* failures (network timeouts, 5xx, 429). Permanent client errors
  (401/403/404) are **not** retried.
- A resource that returns 403/404 (e.g. a project with merge requests disabled)
  is skipped, not fatal. A single item whose notes can't be fetched is stored
  without comments and logged, rather than aborting the whole run.
- Progress is checkpointed after every page, so an interrupted backfill resumes
  from where it left off.

## Notes

- `reindex` reads every stored file; fine for tens of thousands of items.
