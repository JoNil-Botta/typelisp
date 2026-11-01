;; `replace!` of an array element whose type is an owned handle (a dynamic
;; array or a string) swaps the handle stored in the element slot: the old
;; handle comes back intact and the slot holds the replacement. The element's
;; place is its slot, not the handle a borrow of it yields (#8449).
(import stdlib.string)

(define (dyn-elements) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [xss : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) 1)]
    (set! (array-ref xss 0) a)
    (let
      [old : (__tl_dyn-array i64) (replace! (array-ref xss 0) b)]
      ;; 3 in the slot, 2 returned.
      (+ (* 10 (array-length (array-ref xss 0))) (array-length old)))))

(define (string-elements) : i64
  (let
    [names : (Array String 2) (array "ab" "cde")]
    [old : String (replace! (array-ref names 1) "f")]
    ;; 1 in the slot, 3 returned.
    (+
      (* 10 (string.string-length (array-ref names 1)))
      (string.string-length old))))

(define (swap-loop [n : i64]) : i64
  (let
    [xss : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) 1)]
    [other : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [i : i64 0]
    [acc : i64 0]
    (set! (array-ref xss 0) (__tl_make-array i64 2))
    (while (< i n)
      (set! other (replace! (array-ref xss 0) other))
      (set! acc (+ acc (array-length (array-ref xss 0))))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  ;; Exits 42 when every part is right.
  (if (and (= (dyn-elements) 32) (= (string-elements) 13) (= (swap-loop 4) 10))
    42
    1))