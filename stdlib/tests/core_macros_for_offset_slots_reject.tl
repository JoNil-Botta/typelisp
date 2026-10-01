;; A `start` field between `slots` and `len` makes this a window, not a
;; slots/len struct: walking `slots[0, len)` would visit the wrong items, so
;; `for` asks for the module protocol instead.
(defstruct Window
  (slots (__tl_dyn-array i64))
  (start i64)
  (len i64))

(define (main) : i64
  (let
    [window : Window (Window (__tl_make-array i64 4) 1 2)]
    [total : i64 0]
    (begin
      (for [item (& window)]
        (set! total (+ total (deref item))))
      total)))