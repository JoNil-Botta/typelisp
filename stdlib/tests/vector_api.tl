(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)
(import (vector.vector String) as strvec)

(defstruct VectorApiCounter
  (value i64))

(import (vector.vector VectorApiCounter) as countervec)

(defstruct VectorApiPoint
  (x i64)
  (y i64))

(defstruct VectorApiBall
  (center VectorApiPoint)
  (radius i64))

(import (vector.vector VectorApiBall) as ballvec)

(define (increment-all! [items : (&mut items countervec.Vec)]) : unit
  (let
    [iter : (countervec.IterMut items) (countervec.iterator-mut items)]
    [done : bool false]
    (while (not done)
      (match (countervec.next-mut (&mut iter))
        [(countervec.IterMutNext.Done) (set! done true)]
        [(countervec.IterMutNext.Item item) (set! item.value (+ item.value 6))]))))

(define (iter-mut-done? [result : (countervec.IterMutNext source)]) : bool
  (match result
    [(countervec.IterMutNext.Done) true]
    [(countervec.IterMutNext.Item _) false]))

(define (iter-mut-string-is-alpha? [result : (strvec.IterMutNext source)]) : bool
  (match result
    [(strvec.IterMutNext.Done) false]
    [(strvec.IterMutNext.Item item) (string.eq item "alpha")]))

(define (iter-shared-done? [result : (countervec.IterNext source)]) : bool
  (match result
    [(countervec.IterNext.Done) true]
    [(countervec.IterNext.Item _) false]))

(define (iter-shared-string-is-alpha? [result : (strvec.IterNext source)]) : bool
  (match result
    [(strvec.IterNext.Done) false]
    [(strvec.IterNext.Item item) (string.eq item "alpha")]))

(define (iter-shared-i64-count [result : (i64vec.IterNext source)]) : i64
  (match result
    [(i64vec.IterNext.Done) 0]
    [(i64vec.IterNext.Item _) 1]))

(define (shared-counter-value [counter : (& source VectorApiCounter)]) : i64
  (struct-get counter value))

(define (shared-ball-score [ball : (& source VectorApiBall)]) : i64
  (+
    (+
      (struct-get (struct-get ball center) x)
      (struct-get (struct-get ball center) y))
    (struct-get ball radius)))

(define (main) : i64
  (let
    [numbers : i64vec.Vec (i64vec.with-capacity 1)]
    [words : strvec.Vec (strvec.new)]
    [counters : countervec.Vec (countervec.new)]
    [single-counter : countervec.Vec (countervec.new)]
    [empty : countervec.Vec (countervec.new)]
    [shared-empty : countervec.Vec (countervec.new)]
    [balls : ballvec.Vec (ballvec.new)]
    (begin
      (i64vec.push! numbers 10)
      (i64vec.push! numbers 32)
      (i64vec.set! numbers 0 11)
      (i64vec.reverse! numbers)
      (strvec.push! words "alpha")
      (strvec.push! words "beta")
      (countervec.push! counters (VectorApiCounter 10))
      (countervec.push! counters (VectorApiCounter 20))
      (countervec.push! single-counter (VectorApiCounter 9))
      (ballvec.push! balls (VectorApiBall (VectorApiPoint 3 4) 5))
      (ballvec.push! balls (VectorApiBall (VectorApiPoint 1 2) 7))
      (increment-all! (&mut counters))
      (let
        [word-first-alpha : bool
          (let
            [word-iter : (strvec.IterMut words)
              (strvec.iterator-mut (&mut words))]
            (iter-mut-string-is-alpha? (strvec.next-mut (&mut word-iter))))]
        [word-first-alpha-shared : bool
          (let
            [word-iter : (strvec.Iter words) (strvec.iterator (& words))]
            (iter-shared-string-is-alpha? (strvec.next (&mut word-iter))))]
        [empty-iter : (countervec.IterMut empty)
          (countervec.iterator-mut (&mut empty))]
        [empty-shared-iter : (countervec.Iter shared-empty)
          (countervec.iterator (& shared-empty))]
        [shared-numbers-seen : i64
          (let
            [iter : (i64vec.Iter numbers) (i64vec.iterator (& numbers))]
            (+
              (iter-shared-i64-count (i64vec.next (&mut iter)))
              (+
                (iter-shared-i64-count (i64vec.next (&mut iter)))
                (+
                  (iter-shared-i64-count (i64vec.next (&mut iter)))
                  (iter-shared-i64-count (i64vec.next (&mut iter)))))))]
        [shared-counters-total : i64
          (let
            [iter : (countervec.Iter counters)
              (countervec.iterator (& counters))]
            [total : i64 0]
            [done : bool false]
            (begin
              (while (not done)
                (match (countervec.next (&mut iter))
                  [(countervec.IterNext.Done) (set! done true)]
                  [(countervec.IterNext.Item counter)
                    (set! total (+ total (shared-counter-value counter)))]))
              total))]
        [shared-single-counter-total : i64
          (let
            [iter : (countervec.Iter single-counter)
              (countervec.iterator (& single-counter))]
            (match (countervec.next (&mut iter))
              [(countervec.IterNext.Done) 0]
              [(countervec.IterNext.Item counter)
                (shared-counter-value counter)]))]
        [shared-balls-total : i64
          (let
            [iter : (ballvec.Iter balls) (ballvec.iterator (& balls))]
            [total : i64 0]
            [done : bool false]
            (begin
              (while (not done)
                (match (ballvec.next (&mut iter))
                  [(ballvec.IterNext.Done) (set! done true)]
                  [(ballvec.IterNext.Item ball)
                    (set! total (+ total (shared-ball-score ball)))]))
              total))]
        (match (strvec.pop! words)
          [(strvec.Pop.Ok word)
            (if (and
              (= (i64vec.len (& numbers)) 2)
              (= (i64vec.get (& numbers) 0 0) 32)
              (i64vec.contains? (& numbers) 11)
              (string.eq word "beta")
              (string.eq (strvec.get (& words) 0 "") "alpha")
              word-first-alpha
              word-first-alpha-shared
              (=
                (struct-get
                  (countervec.get (& counters) 0 (VectorApiCounter 0))
                  value)
                16)
              (=
                (struct-get
                  (countervec.get (& counters) 1 (VectorApiCounter 0))
                  value)
                26)
              (= shared-numbers-seen 2)
              (= shared-counters-total 42)
              (= shared-single-counter-total 9)
              (= shared-balls-total 22)
              (iter-mut-done? (countervec.next-mut (&mut empty-iter)))
              (iter-mut-done? (countervec.next-mut (&mut empty-iter)))
              (iter-shared-done? (countervec.next (&mut empty-shared-iter)))
              (iter-shared-done? (countervec.next (&mut empty-shared-iter))))
              42
              1)]
          [(strvec.Pop.Empty) 1])))))