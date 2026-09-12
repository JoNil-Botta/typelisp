;; Qualifying the removed prelude bridge through its defining module is no escape.
(import stdlib.core_macros as core)

(define (main) : i64
  (let
    [bad : i64 (core.__tl-compiler-owned-shared-view-dyn-ref-as 0 i64)]
    bad))