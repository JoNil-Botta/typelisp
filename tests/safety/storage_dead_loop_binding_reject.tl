;; A borrow of a loop iteration's binding stored in an outer local read after
;; the loop: the binding's storage ends with each iteration. Typing rejects
;; the store first, as in `storage_dead_inner_scope_used_reject`. Rust: E0597.
(define (last-item [items : (& s (Array i64 3))]) : i64
  (let
    [x : i64 0]
    [r (& x)]
    [i : i64 0]
    (while (< i 3)
      (let
        [x : i64 (array-ref items i)]
        (set! r (& x)))
      (set! i (+ i 1)))
    ; Must fail: the last iteration's `x` is dead here.
    (deref r)))

(define (main) : i64
  0)