;: A safe `spawn` is the thread module's spawn call main's collector sees: its task
;: may assign `g` while `(& g)` is still held for `read` (#7904).
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (field-a [r : (& r Big)]) : (& r i64)
  (& r.a))

(define (read [r : (& r i64)] [n : i64]) : i64
  (+ n (deref r)))

(define (main) : i64
  (read
    (field-a (& g))
    (match (thread_i64.spawn
      (lambda () : i64
        (rebind!)
        0))
      [(thread_i64.I64SpawnErr _) 0]
      [(thread_i64.I64SpawnOk worker)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 0])])))