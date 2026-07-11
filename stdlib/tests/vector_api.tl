(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)
(import (vector.vector String) as strvec)

(defstruct VectorApiCounter
  (value i64))

(import (vector.vector VectorApiCounter) as countervec)

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

(define (main) : i64
  (let
    [numbers : i64vec.Vec (i64vec.with-capacity 1)]
    [words : strvec.Vec (strvec.new)]
    [counters : countervec.Vec (countervec.new)]
    [empty : countervec.Vec (countervec.new)]
    (begin
      (i64vec.push (&mut numbers) 10)
      (i64vec.push (&mut numbers) 32)
      (i64vec.set (&mut numbers) 0 11)
      (i64vec.reverse! (&mut numbers))
      (strvec.push (&mut words) "alpha")
      (strvec.push (&mut words) "beta")
      (countervec.push (&mut counters) (VectorApiCounter 10))
      (countervec.push (&mut counters) (VectorApiCounter 20))
      (increment-all! (&mut counters))
      (let
        [word-first-alpha : bool
          (let
            [word-iter : (strvec.IterMut words)
              (strvec.iterator-mut (&mut words))]
            (iter-mut-string-is-alpha? (strvec.next-mut (&mut word-iter))))]
        [empty-iter : (countervec.IterMut empty)
          (countervec.iterator-mut (&mut empty))]
        (match (strvec.pop (&mut words))
          [(strvec.Pop.Ok word)
            (if (and
              (= (i64vec.len (& numbers)) 2)
              (= (i64vec.get (& numbers) 0 0) 32)
              (i64vec.contains? (& numbers) 11)
              (string.eq word "beta")
              (string.eq (strvec.get (& words) 0 "") "alpha")
              word-first-alpha
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
              (iter-mut-done? (countervec.next-mut (&mut empty-iter)))
              (iter-mut-done? (countervec.next-mut (&mut empty-iter))))
              42
              1)]
          [(strvec.Pop.Empty) 1])))))