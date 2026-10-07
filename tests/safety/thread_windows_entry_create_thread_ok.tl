;; The permitted flow: the entry, through a local of its exact type, is
;; passed to the unsafe `CreateThread` adapter inside `unsafe` (#7742).
;; Check-only; never executed.
(import stdlib.thread)

(define (create-suspended [context : i64]) : i64
  (let
    [entry : (CFunc unsafe-non-null (-> i64 i64)) thread.thread-windows-entry]
    (unsafe
      (thread.thread-windows-create-thread 0 0 entry context (cast 4 : i32) 0))))

(define (main) : i64
  0)