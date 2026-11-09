;; Conservative rejection (D-C216): until lifetimes carry binding identity, a
;; value converts to a name held by a binder only if it also outlives the
;; enclosing lifetime of that name. Rename the binding. Acceptance is the
;; target of #8890; this row flips to check-ok then.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Opt
  (:lifetimes a)
  (None)
  (Some (& a i64)))

(define (f [x : (& q i64)] [y : (& r i64)]) : i64
  (let
    [r : i64 1]
    (deref (ann x : (& r i64)))))

(define (main) : i64
  0)