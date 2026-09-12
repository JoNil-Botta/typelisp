;; Concurrent timestamp sampling must not share mutable OS out-parameters.
;; The assertions check API invariants, not scheduler-dependent elapsed time.
(import stdlib.profile)
(import stdlib.thread)

(define (sample-clock [count : i64]) : i64
  (let
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (< index count)
        (begin
          (if (or
            (<= (profile.now-ticks) 0)
            (< (profile.now-ms) 0)
            (<= (profile.ticks-per-second) 0))
            (set! ok false)
            unit)
          (set! index (+ index 1))))
      (if ok
        42
        1))))

(define (joined-ok? [worker : thread.Thread]) : bool
  (=
    (thread.join-result-value-or
      (unsafe
        (thread.join worker))
      -1)
    42))

(define (main) : i64
  (match (unsafe
    (thread.spawn sample-clock 100000))
    [(thread.ThreadSpawnErr _) 1]
    [(thread.ThreadSpawnOk first)
      (match (unsafe
        (thread.spawn sample-clock 100000))
        [(thread.ThreadSpawnErr _)
          (begin
            (joined-ok? first)
            2)]
        [(thread.ThreadSpawnOk second)
          (let
            [local-ok : bool (= (sample-clock 100000) 42)]
            [first-ok : bool (joined-ok? first)]
            [second-ok : bool (joined-ok? second)]
            (if (and local-ok first-ok second-ok)
              42
              3))])]))