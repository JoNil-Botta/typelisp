;; Dense borrowed storage preserves checked references through anchored opaque
;; words without enabling general DynArray-of-reference lowering. The fixed
;; one-element arrays at the conversion boundaries make the audited one-word
;; compatibility representation explicit while the u64 DynArray grows.
(import stdlib.string)

(define (borrowed-word [value : (& text str)]) : u64
  (let
    [cell : (Array (& text str) 1) (array value)]
    (unsafe
      (ptr-read (ptr-cast (array-data cell) : (Ptr u64))))))

(define (borrowed-from-word [_anchor : (& text str)] [word : u64]) : (&
    text
    str)
  (let
    [cell : (Array u64 1) (array word)]
    (unsafe
      (ptr-read (ptr-cast (array-data cell) : (Ptr (& text str)))))))

(define (main) : i64
  (let
    [owner : String "left-right"]
    [left : (& owner str) (string.substring-view (& owner) 0 4)]
    [right : (& owner str) (string.substring-view (& owner) 5 5)]
    [left-word : u64 (borrowed-word left)]
    [right-word : u64 (borrowed-word right)]
    [words : (__tl_dyn-array u64) (init : (__tl_dyn-array u64))]
    [i : i64 0]
    [ok : bool true]
    (begin
      (array-push! words left-word)
      (array-push! words right-word)
      ;; Repeated pushes force several reallocations while retaining both
      ;; distinct substring words in their original order.
      (while (< i 32)
        (begin
          (array-push!
            words
            (if (= (% i 2) 0)
              left-word
              right-word))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 32)
        (begin
          (set!
            ok
            (and
              ok
              (if (= (% i 2) 0)
                (string.eq
                  (borrowed-from-word (& owner) (array-ref words (+ i 2)))
                  left)
                (string.eq
                  (borrowed-from-word (& owner) (array-ref words (+ i 2)))
                  right))))
          (set! i (+ i 1))))
      (if (and
        ok
        (>= (array-length words) 34)
        (=
          (string.string-length
            (borrowed-from-word (& owner) (array-ref words 0)))
          4)
        (=
          (string.string-length
            (borrowed-from-word (& owner) (array-ref words 1)))
          5)
        (string.eq (borrowed-from-word (& owner) (array-ref words 0)) left)
        (string.eq (borrowed-from-word (& owner) (array-ref words 1)) right))
        42
        1))))