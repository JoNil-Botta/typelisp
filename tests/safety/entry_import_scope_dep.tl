;; Helper for the entry_import_scope_* fixtures (#9678): items that an entry
;; module imports unqualified, including a spelling of a builtin.
(define limit : i64
  40)

(define (helper) : i64
  30)

(define (slice-view [x : i64] [start : i64] [len : i64]) : i64
  (+ x (+ start len)))