;; #8998: a constructor formal spelled like a binding infers under a hidden
;; name, and an argument that only echoes it binds the unshadowed `program`: a
;; `(&mut program T)` reborrow it holds still stays borrowed for the rest of the
;; body, so returning it after a second reborrow is rejected.
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (:lifetimes p)
  (m (&mut p Pt)))

; Must fail: `first` keeps `r` borrowed when `second` reborrows it.
(define (escape [r : (&mut program Pt)] [p : i64]) : (Holder program)
  (let
    [first : (Holder program) (Holder r)]
    [second : (Holder program) (Holder r)]
    first))

(define (main) : i64
  0)