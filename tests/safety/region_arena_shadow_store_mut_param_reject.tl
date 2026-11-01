;; A `with-arena` region spelled like the referent's signature lifetime
;; shadows it: a borrow of arena data stored through the `&mut` parameter
;; outlives the arena. The ownership graph erases arena regions, so typing's
;; store check decides it by the region's name (#8584, #8890).
(import stdlib.string)

(defstruct RefBox
  (:lifetimes a)
  (value (& a str)))

(define (store [b : (&mut (RefBox a))]) : unit
  (with-arena
    a
    (let
      [s : String (string.int->string 1)]
      ; Must fail: the arena `a` resets when `with-arena` ends.
      (set! b.value (& s)))))

(define (main) : i64
  0)