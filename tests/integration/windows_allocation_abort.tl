(import stdlib.runtime)

(define (main) : i64
  (runtime.windows-allocation-abort
    1
    2
    (cast -1 : u64)
    (cast -2 : u64)
    9223372036854775808
    4294967295))