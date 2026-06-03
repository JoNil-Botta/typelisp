(import "stdlib/test.tl")

(import "stdlib/queue.tl")

;; Extractors avoid panic-in-match so the fixture typechecks on every stage0.
(define (deque-pop-ok? [p : I64DequePop]) : bool
  (match p
    [(I64DequePopOk _ _) true]
    [(I64DequePopEmpty) false]))

(define (deque-pop-value-or [p : I64DequePop] [fallback : i64]) : i64
  (match p
    [(I64DequePopOk value _) value]
    [(I64DequePopEmpty) fallback]))

(define (deque-pop-rest-or [p : I64DequePop] [fallback : I64Deque]) : I64Deque
  (match p
    [(I64DequePopOk _ rest) rest]
    [(I64DequePopEmpty) fallback]))

(define (main) : i64
  (begin
    ;; --- empty deque: len/capacity/is-empty? and fallback peeks ---
    (let
      [empty : I64Deque (i64-deque-with-capacity 2)]
      (begin
        (assert-i64-eq (i64-deque-len empty) 0 "empty len 0")
        (assert-i64-eq (i64-deque-capacity empty) 2 "empty capacity 2")
        (assert-true (i64-deque-is-empty? empty) "empty is-empty?")
        (assert-i64-eq
          (i64-deque-peek-front empty -1)
          -1
          "empty peek-front fallback")
        (assert-i64-eq
          (i64-deque-peek-back empty -1)
          -1
          "empty peek-back fallback")
        (assert-i64-eq (i64-deque-get empty 0 -1) -1 "empty get fallback")
        (assert-i64-eq
          (i64-deque-capacity (i64-deque-with-capacity 0))
          1
          "zero capacity clamps to 1")))
    ;; --- FIFO order across push-back/pop-front ---
    (let
      [q3 : I64Deque
        (i64-deque-push-back
          (i64-deque-push-back
            (i64-deque-push-back (i64-deque-with-capacity 3) 10)
            20)
          30)]
      (begin
        (assert-i64-eq (i64-deque-len q3) 3 "three pushes -> len 3")
        (assert-i64-eq (i64-deque-peek-front q3 -1) 10 "front is 10")
        (assert-i64-eq (i64-deque-peek-back q3 -1) 30 "back is 30")
        (assert-i64-eq (i64-deque-get q3 1 -1) 20 "logical get 1 is 20")
        (assert-i64-eq (i64-deque-get q3 -1 -1) -1 "negative get fallback")
        (assert-i64-eq (i64-deque-get q3 3 -1) -1 "get at len fallback")
        (let
          [p1 : I64DequePop (i64-deque-pop-front q3)]
          (begin
            (assert-true (deque-pop-ok? p1) "pop-front has value")
            (assert-i64-eq (deque-pop-value-or p1 -1) 10 "first pop -> 10")
            (let
              [q2 : I64Deque (deque-pop-rest-or p1 q3)]
              [p2 : I64DequePop (i64-deque-pop-front (deque-pop-rest-or p1 q3))]
              (begin
                (assert-i64-eq (i64-deque-peek-front q2 -1) 20 "front now 20")
                (assert-i64-eq (deque-pop-value-or p2 -1) 20 "second pop -> 20")))))))
    ;; --- wraparound then growth preserves logical order ---
    (let
      [base : I64Deque
        (i64-deque-push-back
          (i64-deque-push-back
            (i64-deque-push-back (i64-deque-with-capacity 3) 1)
            2)
          3)]
      [drop1 : I64DequePop (i64-deque-pop-front base)]
      [wrapped : I64Deque
        (i64-deque-push-back (deque-pop-rest-or drop1 base) 4)]
      [grown : I64Deque (i64-deque-push-back wrapped 5)]
      (begin
        (assert-i64-eq (i64-deque-capacity grown) 6 "growth doubles to 6")
        (assert-i64-eq (i64-deque-len grown) 4 "grown len 4")
        (assert-i64-eq (i64-deque-get grown 0 -1) 2 "grown[0] = 2")
        (assert-i64-eq (i64-deque-get grown 1 -1) 3 "grown[1] = 3")
        (assert-i64-eq (i64-deque-get grown 2 -1) 4 "grown[2] = 4")
        (assert-i64-eq (i64-deque-get grown 3 -1) 5 "grown[3] = 5")
        (assert-i64-eq (i64-deque-peek-front grown -1) 2 "grown front")
        (assert-i64-eq (i64-deque-peek-back grown -1) 5 "grown back")))
    ;; --- double-ended push/pop and reuse after draining ---
    (let
      [dq : I64Deque
        (i64-deque-push-front
          (i64-deque-push-back (i64-deque-with-capacity 2) 20)
          10)]
      (begin
        (assert-i64-eq (i64-deque-get dq 0 -1) 10 "push-front at front")
        (assert-i64-eq (i64-deque-get dq 1 -1) 20 "push-back at back")
        (let
          [back : I64DequePop (i64-deque-pop-back dq)]
          (begin
            (assert-i64-eq (deque-pop-value-or back -1) 20 "pop-back -> 20")
            (let
              [front : I64DequePop
                (i64-deque-pop-front (deque-pop-rest-or back dq))]
              (begin
                (assert-i64-eq
                  (deque-pop-value-or front -1)
                  10
                  "pop-front -> 10")
                (let
                  [drained : I64Deque (deque-pop-rest-or front dq)]
                  (begin
                    (assert-true
                      (i64-deque-is-empty? drained)
                      "drained is empty")
                    (let
                      [again : I64Deque (i64-deque-push-back drained 99)]
                      (begin
                        (assert-i64-eq (i64-deque-len again) 1 "reuse len 1")
                        (assert-i64-eq
                          (i64-deque-peek-front again -1)
                          99
                          "reuse front 99")))))))))))
    ;; --- empty pops return Empty ---
    (let
      [empty-pop-front : I64DequePop (i64-deque-pop-front (i64-deque-new))]
      [empty-pop-back : I64DequePop (i64-deque-pop-back (i64-deque-new))]
      (begin
        (assert-false (deque-pop-ok? empty-pop-front) "empty pop-front")
        (assert-false (deque-pop-ok? empty-pop-back) "empty pop-back")))
    42))