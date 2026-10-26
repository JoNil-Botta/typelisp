;; A by-value match moves only what its pattern binds by move (Rust's place
;; semantics): a Copy payload binding, `_` and an unbound tuple slot or array
;; element leave the rest of the scrutinee in place and usable (#8449).
(import stdlib.string)

(defenum Msg
  (Text String)
  (Code i64))

(define (take-s [s : String]) : i64
  (string.string-length (& s)))

(define (take-msg [m : Msg]) : i64
  (match m
    [(Msg.Text s) (take-s s)]
    [(Msg.Code c) c]))

(define (enum-copy-binding [m : Msg]) : i64
  (+
    (match m
      [(Msg.Text _) 0]
      [(Msg.Code c) c])
    (take-msg m)))

(define (enum-wildcard [m : Msg]) : i64
  (+
    (match m
      [_ 1])
    (take-msg m)))

(define (tuple-other-slot [p : (Tuple String String)]) : i64
  (+
    (match p
      [(tuple a _) (take-s a)])
    (take-s (tuple-ref p 1))))

(define (array-other-element [p : (Array String 2)]) : i64
  (+
    (match p
      [(array a _) (take-s a)])
    (take-s (array-ref p 1))))

(define (main) : i64
  (+
    (enum-copy-binding (Msg.Code 10))
    (enum-wildcard (Msg.Text (string.copy "abcd")))
    (tuple-other-slot (tuple (string.copy "ab") (string.copy "cde")))
    (array-other-element (array (string.copy "abcdefghij") (string.copy "ab")))))