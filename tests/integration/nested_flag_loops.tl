;; Nested flag loops sharing one flag: the outer `(while (and (< k n) ok) ...)`
;; runs an inner `(while (and (< b m) ok) ...)` on the same `ok`, so the inner
;; loop is entered with a flag the outer test has just proved true. At opt 2
;; that seed is a literal and both loops convert to direct exits; every opt
;; level must print the same verdicts. The cases hit each clear site: a bad
;; separator, a mismatch inside the inner loop, an exhausted input and a full
;; match, plus a flag that is still read after both loops.
(import stdlib.io)
(import stdlib.string)

(define (match-words
  [path : (& path str)]
  [want : (& want str)]
  [segments : i64]) : i64
  (let
    [n : i64 (string.string-length path)]
    [m : i64 (string.string-length want)]
    [pos : i64 0]
    [k : i64 0]
    [ok : bool true]
    (begin
      (while (and (< k segments) ok)
        (begin
          (if (or (>= pos n) (not (= (string.string-ref path pos) '/')))
            (set! ok false)
            (let
              [b : i64 0]
              (begin
                (while (and (< b m) ok)
                  (if (or
                    (>= (+ pos (+ b 1)) n)
                    (not
                      (=
                        (string.string-ref path (+ pos (+ b 1)))
                        (string.string-ref want b))))
                    (set! ok false)
                    (set! b (+ b 1))))
                (set! pos (+ pos (+ m 1))))))
          (set! k (+ k 1))))
      (if ok
        (+ (* k 100) pos)
        (- 0 (+ (* k 100) pos))))))

(define (main) : i64
  (begin
    (io.println "{}" (match-words "/ab/ab/ab" "ab" 3))
    (io.println "{}" (match-words "/ab/ax/ab" "ab" 3))
    (io.println "{}" (match-words "/ab-ab/ab" "ab" 3))
    (io.println "{}" (match-words "/ab/a" "ab" 3))
    (io.println "{}" (match-words "" "ab" 0))
    (io.println "{}" (match-words "/ab/ab" "" 2))
    42))