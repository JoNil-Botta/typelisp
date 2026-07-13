# AVX-512 retired-instruction counter

`counter.tl` is the zero-third-party Linux launcher used by
`scripts/measure-spmd-avx512-instructions.sh`. It opens the hardware retired
instruction event directly with `perf_event_open`, pins the child to one
logical CPU, and synchronizes through a pipe so the disabled inherited event
is attached before `execve` enables it.

The event counts user space only (`inherit=1`, `exclude_kernel=1`,
`exclude_hv=1`, `enable_on_exec=1`). The launcher rejects zero, unavailable,
not-running, or multiplexed counters and reports `EPERM`, `EACCES`, and
`ENOSYS` explicitly. It also decodes the raw `wait4` status so SIGILL is never
mistaken for a valid short measurement.

Build and run it directly on Linux/WSL:

```sh
typelisp build tools/spmd-avx512-perf/counter.tl \
  -o target/spmd-avx512-counter --target linux-x86_64 --opt-level 2
target/spmd-avx512-counter --cpu 4 -- /bin/true
```

Successful output is one tab-separated row containing the retired count, exit
status, signal, time enabled, and time running. Normal users should run the
measurement script, which owns ISA/PMU preflight, parity checks, repetitions,
host fingerprinting, and reporting.
