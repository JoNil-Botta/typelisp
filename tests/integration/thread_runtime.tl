(import "stdlib/thread.tl")

(define (integration-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (integration-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (integration-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast (ptr-offset (integration-addr->mut-i64 addr) slot) : (Ptr i64)))))

(define (integration-write-i64! [addr : i64] [slot : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset (integration-addr->mut-i64 addr) slot) value)))

(define integration-worker-iterations : i64
  512)

(define (integration-worker-expected [base : i64]) : i64
  (+
    (* integration-worker-iterations (+ base 7))
    (/ (* (- integration-worker-iterations 1) integration-worker-iterations) 2)))

(define (integration-worker [ctx : i64]) : i64
  (let
    [out-addr : i64 (integration-read-i64 ctx 0)]
    [value : i64 (integration-read-i64 ctx 1)]
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i integration-worker-iterations)
        (let
          [buf : (Array i64) (make-array i64 16)]
          (begin
            (array-set! buf 0 (+ value i))
            (array-set! buf 15 (+ (array-ref buf 0) 7))
            (set! sum (+ sum (array-ref buf 15)))
            (set! i (+ i 1)))))
      (integration-write-i64! out-addr 0 sum)
      sum)))

(define (integration-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (integration-finish-run
  [a : Thread]
  [b : Thread]
  [c : Thread]
  [d : Thread]
  [out-a : (Array i64)]
  [out-b : (Array i64)]
  [out-c : (Array i64)]
  [out-d : (Array i64)]) : i64
  (let
    [a-code : i64 (integration-join-code (thread-join a))]
    [b-code : i64 (integration-join-code (thread-join b))]
    [c-code : i64 (integration-join-code (thread-join c))]
    [d-code : i64 (integration-join-code (thread-join d))]
    [a-expected : i64 (integration-worker-expected 11)]
    [b-expected : i64 (integration-worker-expected 31)]
    [c-expected : i64 (integration-worker-expected 41)]
    [d-expected : i64 (integration-worker-expected 59)]
    (cond
      [(not (= a-code a-expected)) 3]
      [(not (= b-code b-expected)) 4]
      [(not (= c-code c-expected)) 5]
      [(not (= d-code d-expected)) 6]
      [(not (= (array-ref out-a 0) a-expected)) 7]
      [(not (= (array-ref out-b 0) b-expected)) 8]
      [(not (= (array-ref out-c 0) c-expected)) 9]
      [(not (= (array-ref out-d 0) d-expected)) 10]
      [else 42])))

(define (integration-run-threads
  [out-a : (Array i64)]
  [out-b : (Array i64)]
  [out-c : (Array i64)]
  [out-d : (Array i64)]
  [ctx-a : (Array i64)]
  [ctx-b : (Array i64)]
  [ctx-c : (Array i64)]
  [ctx-d : (Array i64)]) : i64
  (match (thread-spawn integration-worker (integration-array-i64-addr ctx-a))
    [(ThreadSpawnErr _) 11]
    [(ThreadSpawnOk a)
      (match (thread-spawn
        integration-worker
        (integration-array-i64-addr ctx-b))
        [(ThreadSpawnErr _) 12]
        [(ThreadSpawnOk b)
          (match (thread-spawn
            integration-worker
            (integration-array-i64-addr ctx-c))
            [(ThreadSpawnErr _) 13]
            [(ThreadSpawnOk c)
              (match (thread-spawn
                integration-worker
                (integration-array-i64-addr ctx-d))
                [(ThreadSpawnErr _) 14]
                [(ThreadSpawnOk d)
                  (integration-finish-run a b c d out-a out-b out-c out-d)])])])]))

(define (main) : i64
  (let
    [out-a : (Array i64) (make-array i64 1)]
    [out-b : (Array i64) (make-array i64 1)]
    [out-c : (Array i64) (make-array i64 1)]
    [out-d : (Array i64) (make-array i64 1)]
    [ctx-a : (Array i64) (make-array i64 2)]
    [ctx-b : (Array i64) (make-array i64 2)]
    [ctx-c : (Array i64) (make-array i64 2)]
    [ctx-d : (Array i64) (make-array i64 2)]
    (begin
      (array-set! ctx-a 0 (integration-array-i64-addr out-a))
      (array-set! ctx-a 1 11)
      (array-set! ctx-b 0 (integration-array-i64-addr out-b))
      (array-set! ctx-b 1 31)
      (array-set! ctx-c 0 (integration-array-i64-addr out-c))
      (array-set! ctx-c 1 41)
      (array-set! ctx-d 0 (integration-array-i64-addr out-d))
      (array-set! ctx-d 1 59)
      (if (< (thread-default-worker-count) 1)
        1
        (integration-run-threads
          out-a
          out-b
          out-c
          out-d
          ctx-a
          ctx-b
          ctx-c
          ctx-d)))))