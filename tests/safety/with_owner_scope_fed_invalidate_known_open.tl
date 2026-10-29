;; Known open (#9476 d6/d9/d11, deferred to #9445 / D-C47 S4): the `with`
;; owner lives in a younger `with-arena` scope but holds a value fed from `o`.
;; Admission records no edge from that value to `o`, so neither this call nor a
;; safe destroy of `o` sees the owner; S4 turns this row into a rejection.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (main) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      scratch
      (with
        ([w (TextOwner t) cleanup-text-owner])
        (begin
          (release o)
          (if (string.string=? (& w.text) "owner-text")
            42
            7))))))