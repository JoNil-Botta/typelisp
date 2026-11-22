;; A module-level global whose only uses are direct `set!`s and that nothing
;; reads has no observer for those stores: the `dead_global_store` stage drops
;; them and DCE removes the values. Every case below either keeps a channel that
;; must still see the write or checks that an effectful stored value is still
;; evaluated, so the rule can only hold if what it removed was unobservable.
;; Written in two places and never read: the shape the rule removes.
(define dead-store : i64
  0)

;; The stored value's own effect: still observable after the store is gone.
(define effect-log : i64
  0)

;; Read once, from another function: kept.
(define live-read : i64
  0)

;; Address taken and read through the pointer: kept.
(define addressed : i64
  0)

;; Written through the pointer and read directly: kept.
(define poked : i64
  0)

;; Stored per iteration of a loop that otherwise does not mention it.
(define loop-dead : i64
  0)

(define (bump) : i64
  (begin
    (set! effect-log (+ effect-log 1))
    7))

(define (write-dead) : unit
  (begin
    (set! dead-store (bump))
    (set! dead-store 3)
    unit))

(define (read-live) : i64
  live-read)

(define (read-addressed) : i64
  (let
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of addressed))]
    (unsafe
      (ptr-read p))))

(define (write-addressed) : unit
  (set! addressed 6))

(define (poke) : unit
  (let
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of poked))]
    (unsafe
      (ptr-write! p 9))))

(define (loop-write [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (while (< i n)
      (begin
        (set! loop-dead i)
        (set! sum (+ sum i)))
      (set! i (+ i 1)))
    sum))

(define (main) : i64
  (begin
    (write-dead)
    (set! live-read 5)
    (write-addressed)
    (poke)
    (let
      [sum : i64 (loop-write 7)]
      (cond
        [(not (= effect-log 1)) 10]
        [(not (= (read-live) 5)) 11]
        [(not (= (read-addressed) 6)) 12]
        [(not (= poked 9)) 13]
        [(not (= sum 21)) 14]
        ;; A long enough loop that the store's block still runs: a dropped
        ;; store must not change the arithmetic around it.
        [(not (= (loop-write 1000) 499500)) 15]
        [else 42]))))