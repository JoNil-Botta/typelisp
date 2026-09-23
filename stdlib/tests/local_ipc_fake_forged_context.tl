;; Runtime trap test: adapter functions are ordinary function values anyone can
;; call, so the fake treats its context as a row number it checks, never as an
;; address. A context no `fake.new` returned traps with the bounds diagnostic.
(import stdlib.local_ipc)
(import stdlib.local_ipc_fake as fake)

(define (main) : i64
  (let
    [real : i64 (fake.new)]
    [adapter : local_ipc.LocalIpcAdapter (fake.adapter (+ real 1))]
    (adapter.now-ms adapter.context)))