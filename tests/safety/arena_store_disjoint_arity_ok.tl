(import stdlib.string)

(define saved : String
  "")

(define (unrelated [_arg0 : i64] [_arg1 : i64] [_arg2 : i8] [_arg3 : u8]) : bool
  (set! saved (string.append "unrelated " "callback"))
  true)

(define (good [_a : String] [_b : String]) : bool
  true)

(define (invoke [cmp : (-> String String bool)]) : bool
  (cmp "a" "b"))

(define (safe) : bool
  (invoke good))

(define (main) : i64
  (let
    [_other : (-> i64 i64 i8 u8 bool) unrelated]
    (with-arena
      job
      (if (safe)
        42
        0))))