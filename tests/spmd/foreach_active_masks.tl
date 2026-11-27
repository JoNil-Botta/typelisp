;; Exercise empty, singleton, all-active, sparse and partial final masks
;; with the same oracle on every gang width.
(define (count-lanes [n : i64] [wanted : i64] [all : bool]) : bool
  (let
    [seen : i64 0]
    [expected : i64 0]
    [ok : bool true]
    (foreach
      ([i : i64 0 n])
      (let
        [flag : bool (= i wanted)]
        (if (or all flag)
          (foreach-active
            [lane : i64]
            (set!
              ok
              (and
                ok
                (=
                  (lane-value i)
                  (if all
                    expected
                    wanted))
                (= (lane-value flag) (= (lane-value i) wanted))))
            (set! seen (+ seen 1))
            (set! expected (+ expected 1)))
          unit)))
    (and
      ok
      (=
        seen
        (if all
          n
          (if (and (>= wanted 0) (< wanted n))
            1
            0))))))

(define (bool-lanes) : bool
  (let
    [flags : (__tl_dyn-array bool) (__tl_make-array bool 67)]
    [j : i64 0]
    [total : i64 0]
    [ok : bool true]
    (while (< j 67)
      (set! (array-ref flags j) (= (% j 7) 0))
      (set! j (+ j 1)))
    (foreach
      ([i : i64 0 67])
      (let
        [flag : bool (array-ref flags i)]
        (if flag
          (foreach-active
            [lane : i64]
            (set! ok (and ok (lane-value flag) (= (lane-value i) (* total 7))))
            (set! total (+ total 1)))
          unit)))
    (and ok (= total 10))))

(defenum Choice
  (Skip)
  (Take i64))

(define (visit [xs : (& xs (__tl_dyn-array Choice))] [n : i64]) : i64
  (let
    [trace : i64 0]
    (foreach
      ([i : i64 0 n])
      (match (array-ref xs i)
        [Skip unit]
        [(Take x)
          (foreach-active
            [lane : i64]
            (set! trace (+ (* trace 10) (lane-value x))))]))
    trace))

(define (enum-payload) : bool
  (let
    [xs : (__tl_dyn-array Choice) (__tl_make-array Choice 5)]
    (set! (array-ref xs 0) (Take 4))
    (set! (array-ref xs 1) Skip)
    (set! (array-ref xs 2) (Take 2))
    (set! (array-ref xs 3) Skip)
    (set! (array-ref xs 4) Skip)
    (= (visit (& xs) 5) 42)))

(define (main) : i64
  (if (and
    (enum-payload)
    (bool-lanes)
    (count-lanes 0 0 true)
    (count-lanes 37 -1 false)
    (count-lanes 37 19 false)
    (count-lanes 37 35 true))
    42
    1))