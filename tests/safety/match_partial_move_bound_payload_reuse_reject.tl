;; A by-value match that binds a move-only payload moves it out of the
;; scrutinee, which cannot be used whole afterwards (#8449).
(import stdlib.string)

(defenum Msg
  (Text String)
  (Code i64))

(define (take-s [s : String]) : i64
  (string.string-length (& s)))

(define (take-msg [m : Msg]) : i64
  0)

(define (f [m : Msg]) : i64
  (+
    (match m
      [(Msg.Text s) (take-s s)]
      [(Msg.Code c) c])
    (take-msg m)))

(define (main) : i64
  42)