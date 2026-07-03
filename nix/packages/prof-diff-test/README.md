# prof-diff-test

Differential GHC **compiler** profiles across two build trees.

Runs one or more testsuite tests under two GHC build trees (each built with a
`+profiled_ghc` flavour), captures a JSON cost-centre profile of the compiler
(`+RTS -pj`) for each, and per test renders:

- an individual flame graph per tree, and
- a [differential flame graph](http://www.brendangregg.com/blog/2014-11-09/differential-flame-graphs.html)
  A → B (`difffolded.pl | flamegraph.pl`).

If a test measures heap rather than total allocations — i.e. its `all.T`
declaration uses a residency metric (`collect_compiler_residency`, i.e.
`peak_megabytes_allocated` / `max_bytes_used`) — heap profiles are also taken:
each tree additionally gets a `<tree>-heap.hp` (rendered to SVG with
`hp2pretty`) and a `<tree>-heap.eventlog` carrying the same heap samples
(`-l-agu`, written to a script-controlled path with `-ol`; rendered to
interactive HTML with `eventlog2html`), and the peak-heap A → B delta is
reported. For residency tests the `.hp` comes from the `-hT` that the
testsuite driver itself adds (`RESIDENCY_OPTS`; a second heap-profile flag
would be an RTS error), so `-hc` is only passed when `--heap` forces heap
profiling on a non-residency test. Auto-detection can be overridden with
`--heap` / `--no-heap`.

A failure in one test (or one tree) doesn't abort the run: whatever artifacts
can be produced are, everything missing is reported at the end (with exit code
1), and the run closes with a per-test summary table of the A/B totals and
heap peaks.

The raw `<tree>.prof` files are JSON and load directly into
[speedscope](https://www.speedscope.app/) for per-tree inspection.

## Usage

```
prof-diff-test [options] <baseA> <rootA> <baseB> <rootB> <test>...
```

- `<baseA>`/`<baseB>` — path to each GHC source worktree.
- `<rootA>`/`<rootB>` — `hadrian-util` build-root *name* (`""`/`default` ⇒ `_build`,
  `debug` ⇒ `_build-debug`, …).
- `<test>...` — one or more testsuite tests (each `--only=`); accepts several
  args and/or a single space-separated string. One `hadrian-util` run per tree
  per test; artifacts land in `<out>/<test>/`.

Options: `-o DIR` (work dir), `-j N` (hadrian parallelism), `-m alloc|ticks`
(measurement), `--heap`/`--no-heap` (force/disable heap profiling; default
auto-detects from the test's declared metrics), `--no-flavour-check`, `-h`.

## How it works

Sets `EXTRA_HC_OPTS="+RTS -pj -po<stem> -RTS"`, which hadrian folds into
`ghc_compiler_always_flags`, so every test compile runs the (profiled) GHC with
those RTS options and `-pj` writes a JSON profile to `<stem>.prof`. A fixed
`<stem>` per tree per test yields a single file (if a test invokes GHC more than
once they all write the same file, last wins — intentional).

`hadrian-util`, `flamegraph.pl`, `difffolded.pl`, `hp2pretty` and
`eventlog2html` are put on `PATH` by the Nix wrapper.
