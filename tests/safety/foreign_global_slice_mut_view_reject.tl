;; #7976: only `foreign_global_dep` may write its globals; a mutable slice view
;; of a bare foreign global borrows it mutably and is rejected.
(import foreign_global_dep.slots)

(define (poke [view : (&mut (Slice i64))]) : unit
  (set! (array-ref view 0) 9))

(define (main) : i64
  (begin
    (poke (slice-mut-view slots 1 2))
    (array-ref slots 1)))