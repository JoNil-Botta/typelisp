;; A match on a move-only enum read through `&mut` binds views of its parts
;; whatever the scrutinee's form, so a write through a binder lands in the
;; referent (#8889 review: a `begin` scrutinee bound a frame copy and the write
;; was lost).
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defenum E
  (A In)
  (B i64))

(defstruct Out
  (e E)
  (s In))

(define (poke [p : (&mut p Out)]) : unit
  (match (begin
    p.e)
    [(A x) (set! x.n 9)]
    [(B _) unit]))

(define (main) : i64
  (let
    [o : Out (Out (E.A (In (box 42) 1 2)) (In (box 5) 5 5))]
    (poke (&mut o))
    (match o.e
      [(A x)
        (if (= x.n 9)
          42
          1)]
      [(B _) 2])))