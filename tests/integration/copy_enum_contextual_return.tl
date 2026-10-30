;; Refs #9502 Refs #9493. Copy reads drop an incidental container view at a contextual join.
(defstruct Picks
  (slots (__tl_dyn-array Pick))
  (len i64))

(define (get [items : (& items Picks)] [index : i64] [fallback : Pick]) : Pick
  (if (and (>= index 0) (< index items.len))
    (array-ref items.slots index)
    fallback))

(define (main) : i64
  (let
    [slots (__tl_make-array Pick 2)]
    (set! (array-ref slots 0) Pick.A)
    (set! (array-ref slots 1) Pick.B)
    (let
      [items (Picks slots 2)]
      (if (and
        (=
          (match (get (& items) 0 Pick.B)
            [(A) 42]
            [(B) 7])
          42)
        (=
          (match (get (& items) 8 Pick.A)
            [(A) 42]
            [(B) 7])
          42))
        42
        7))))