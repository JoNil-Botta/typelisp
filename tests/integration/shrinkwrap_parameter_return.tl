;; The recursive base case returns an incoming parameter. Its guard loads a
;; field from memory, while the other arm calls helpers and needs a frame.
;; Shrink wrapping must keep any move into the result register before the
;; early return, whose assembly reads that register implicitly.
(import stdlib.string)

(defstruct ReturnNames
  (slots (__tl_dyn-array String))
  (len i64))

(define (segment-equal? [text : (& text str)] [start : i64] [part : String]) : bool
  (let
    [length : i64 (string.string-length part)]
    [index : i64 0]
    (if (or (< start 0) (> (+ start length) (string.string-length text)))
      false
      (begin
        (while (and
          (< index length)
          (=
            (string.string-ref text (+ start index))
            (string.string-ref part index)))
          (set! index (+ index 1)))
        (= index length)))))

(define (names-end
  [signature : (& signature str)]
  [names : (& names ReturnNames)]
  [extra : i64]
  [index : i64]
  [position : i64]) : i64
  (if (>= index names.len)
    position
    (let
      [name : String (string.copy (& (array-ref names.slots index)))]
      [next : i64 (+ position extra (string.string-length name))]
      (if (and
        (segment-equal? signature position " ")
        (segment-equal? signature (+ position 1) name))
        (names-end signature names extra (+ index 1) next)
        -1))))

(define (main) : i64
  (let
    [signature : String "(-> i64 i64 i64)"]
    [names : ReturnNames (ReturnNames (__tl_make-array "i64" "i64") 2)]
    (if (= (names-end (& signature) (& names) 1 0 3) 11)
      42
      1)))