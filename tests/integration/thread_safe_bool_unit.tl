(import "stdlib/thread.tl")

(define (thread-safe-bool-join-value [thread : ThreadBool]) : bool
  (match (thread-join-bool thread)
    [(ThreadBoolJoinOk value) value]
    [(ThreadBoolJoinErr _) false]))

(define (thread-safe-unit-join-ok? [thread : ThreadUnit]) : bool
  (match (thread-join-unit thread)
    [(ThreadUnitJoinOk) true]
    [(ThreadUnitJoinErr _) false]))

(define (thread-safe-bool-run) : i64
  (let
    [base : i64 39]
    [enabled : bool true]
    (match (thread-spawn-bool
      (lambda () : bool
        (and enabled (= (+ base 3) 42))))
      [(ThreadBoolSpawnErr _) 1]
      [(ThreadBoolSpawnOk worker)
        (if (thread-safe-bool-join-value worker)
          42
          2)])))

(define (thread-safe-unit-run) : i64
  (let
    [base : i64 40]
    (match (thread-spawn-unit
      (lambda () : unit
        (if (= (+ base 2) 42)
          unit
          unit)))
      [(ThreadUnitSpawnErr _) 3]
      [(ThreadUnitSpawnOk worker)
        (if (thread-safe-unit-join-ok? worker)
          42
          4)])))

(define (main) : i64
  (let
    [bool-code : i64 (thread-safe-bool-run)]
    (if (not (= bool-code 42))
      bool-code
      (thread-safe-unit-run))))