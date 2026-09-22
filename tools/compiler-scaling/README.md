# Compiler scaling fixtures

`main.tl` prints one deterministic, self-checking TypeLisp program for a
dimension and a size:

```sh
typelisp run tools/compiler-scaling/main.tl -- cfg 1000 > cfg_1000.tl
```

Dimensions are `decls` (declaration count), `cfg` (size of one function) and
`fields` (width of one struct). A size is a decimal integer from 1 to 1000000;
anything else, an unknown dimension or a wrong argument count prints the usage
and exits 2. The same arguments always produce the same bytes.

Every program returns 42 from `main` only when it reproduces the value the
generator computed for it, so a consumer can prove an input was compiled
correctly before treating it as a measurement.

The required gate that uses these fixtures, its metrics and its budget file
are described under "Compiler scaling budgets" in
[`../../perf/README.md`](../../perf/README.md). `fields` stays at or below 1,000
fields there: members past index 1000 are affected by #7921.
