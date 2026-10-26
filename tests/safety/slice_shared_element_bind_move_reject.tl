;; A Slice element read through a shared reference is the place `(deref s)[i]`:
;; binding it by value moves it out of borrowed content, which would leave an
;; owned String aliasing the slice's element (#8449, #8695).
(define (first-len [s : (& s (Slice String))]) : i64
  (let
    [_owned : String (array-ref s 0)]
    42))

(define (main) : i64
  42)