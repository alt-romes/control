# prof-diff-test

Differential GHC **compiler** profiles across two build trees.

Runs one or more testsuite tests under two GHC build trees (each built with a
`+profiled_ghc` flavour), captures a JSON cost-centre profile of the compiler
(`+RTS -pj`) for each, and per test renders:

- an individual flame graph per tree, and
- a [differential flame graph](http://www.brendangregg.com/blog/2014-11-09/differential-flame-graphs.html)
  A → B (`difffolded.pl | flamegraph.pl`).

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
(measurement), `--no-flavour-check`, `-h`.

## How it works

Sets `EXTRA_HC_OPTS="+RTS -pj -po<stem> -RTS"`, which hadrian folds into
`ghc_compiler_always_flags`, so every test compile runs the (profiled) GHC with
those RTS options and `-pj` writes a JSON profile to `<stem>.prof`. A fixed
`<stem>` per tree per test yields a single file (if a test invokes GHC more than
once they all write the same file, last wins — intentional).

`hadrian-util`, `flamegraph.pl` and `difffolded.pl` are put on `PATH` by the Nix
wrapper.
