(define hits : i64
  0)

(define (main) : i64
  ;; lint-allow: nested-let -- retain the canonical callable/argument lifetime scopes.
  (let
    [get
      ;; lint-allow: unused-variable -- the elided owned input is intentionally unused.
      (lambda ([q : (& i64)]) : unit
        (set! hits (+ hits 1)))]
    (let
      [one : i64 1]
      [two : i64 2]
      (get (& one))
      (get (& two))
      (+ hits 40))))