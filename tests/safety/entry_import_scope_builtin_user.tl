;; Helper for entry_import_scope_builtin_ok: `slice-view` here is the builtin,
;; not the entry module's unqualified import of entry_import_scope_dep.
(define (user-count) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (array-length (slice-view (& xs) 0 2))))