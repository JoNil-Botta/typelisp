; Game-style arena lifetime cookbook:
; - global state lives in the default program arena
; - level state lives inside one lexical with-arena scope
; - frame-only temporaries live inside a nested lexical with-arena scope
; - one frame result is cloned out of a first-class scratch arena with with-escape
; - double-buffered frame arenas are reused only after phase-local values die
; - event-driven unload destroys an atomic level arena only after users join
(import stdlib.arena)
(import stdlib.profile)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import stdlib.string)
(import stdlib.test)

(defstruct GlobalState
  (title String)
  (frame-count i64))

(defstruct LevelState
  (frame-scores (Array i64 3))
  (total-score i64))

(define (frame-temp-score [frame-index : i64]) : i64
  (let
    [before : i64 (profile.alloc-live)]
    [score : i64
      (with-arena
        frame
        (let
          [prefix : String "visible:"]
          [index-text : String (string.int->string frame-index)]
          [label : String (string.append (& prefix) (& index-text))]
          (string.string-length (& label))))]
    [after : i64 (profile.alloc-live)]
    (begin
      (test.assert-i64-eq
        after
        before
        "per-frame with-arena should restore live bytes")
      score)))

(define (frame-summary
  [scratch : arena.Arena]
  [frame-index : i64]
  [score : i64]) : String
  (with-escape
    scratch
    (let
      [frame-text : String (string.int->string frame-index)]
      [score-text : String (string.int->string score)]
      [prefix : String (string.append "frame:" frame-text)]
      [suffix : String (string.append "/score:" score-text)]
      (string.append prefix suffix))))

(define (run-level [global : GlobalState]) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [result : i64
      (with-arena
        level
        (let
          [frame-count : i64 (struct-get global frame-count)]
          [frame-scores : (Array i64 3) (array 0 0 0)]
          [frame-index : i64 0]
          [total : i64 0]
          (begin
            (while (< frame-index frame-count)
              (let
                [score : i64 (frame-temp-score frame-index)]
                [summary : String (frame-summary scratch frame-index score)]
                (begin
                  (array-set! frame-scores frame-index score)
                  (test.assert-i64-eq
                    (string.string-length (& summary))
                    15
                    "frame summary length")
                  (set! total (+ total score))
                  (set! frame-index (+ frame-index 1)))))
            (let
              [state : LevelState (LevelState frame-scores total)]
              [global-title : String (struct-get global title)]
              [first : String
                (frame-summary
                  scratch
                  0
                  (array-ref (struct-get state frame-scores) 0))]
              [last : String
                (frame-summary
                  scratch
                  2
                  (array-ref (struct-get state frame-scores) 2))]
              [want-title : String "arena-cookbook"]
              [want-first : String "frame:0/score:9"]
              [want-last : String "frame:2/score:9"]
              (begin
                (test.assert-string-eq
                  (& global-title)
                  (& want-title)
                  "global title")
                (test.assert-string-eq
                  (& first)
                  (& want-first)
                  "first frame summary")
                (test.assert-string-eq
                  (& last)
                  (& want-last)
                  "last frame summary")
                (test.assert-i64-eq
                  (struct-get global frame-count)
                  3
                  "global state should remain available inside level")
                (test.assert-i64-eq
                  (struct-get state total-score)
                  27
                  "level total score")
                42)))))]
    (begin
      (arena.destroy-safe! scratch)
      result)))

(define (run-double-buffered-frames) : i64
  (let
    [frame-a : arena.Arena (arena.make)]
    [frame-b : arena.Arena (arena.make)]
    [phase-a0 : arena.ArenaPhase (arena.phase frame-a)]
    [label-a0 : String
      (in-arena frame-a (string.append "frame:" (string.int->string 0)))]
    [score-a0 : i64 (string.string-length (& label-a0))]
    [phase-b0 : arena.ArenaPhase (arena.phase frame-b)]
    [label-b1 : String
      (in-arena frame-b (string.append "frame:" (string.int->string 1)))]
    [score-b1 : i64 (string.string-length (& label-b1))]
    (begin
      (arena.rewind-safe! phase-a0)
      (let
        [phase-a1 : arena.ArenaPhase (arena.phase frame-a)]
        [label-a2 : String
          (in-arena frame-a (string.append "frame:" (string.int->string 2)))]
        [score-a2 : i64 (string.string-length (& label-a2))]
        (begin
          (arena.rewind-safe! phase-b0)
          (let
            [phase-b1 : arena.ArenaPhase (arena.phase frame-b)]
            [label-b3 : String
              (in-arena frame-b (string.append "frame:" (string.int->string 3)))]
            [score-b3 : i64 (string.string-length (& label-b3))]
            [total : i64 (+ (+ score-a0 score-b1) (+ score-a2 score-b3))]
            (begin
              (arena.rewind-safe! phase-a1)
              (arena.rewind-safe! phase-b1)
              (arena.destroy-safe! frame-a)
              (arena.destroy-safe! frame-b)
              total)))))))

(define (arena-lifetimes-join-i64 [worker : thread_i64.Handle]) : i64
  (match (thread_i64.join worker)
    [(thread_i64.I64JoinOk value) value]
    [(thread_i64.I64JoinErr _) -1]))

(define (run-event-driven-unload) : i64
  (let
    [level : arena.Arena (arena.make-atomic)]
    [level-name : String (in-arena level (string.append "level:" "docks"))]
    (match (thread_i64.spawn
      (lambda () : i64
        (string.string-length (& level-name))))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (let
          [worker-score : i64 (arena-lifetimes-join-i64 worker)]
          [name-score : i64 (string.string-length (& level-name))]
          (begin
            (arena.destroy-safe! level)
            (if (and (= worker-score name-score) (= name-score 11))
              42
              2)))])))

(define (run-game) : i64
  (let
    [title-prefix : String "arena"]
    [title : String (string.append title-prefix "-cookbook")]
    [global : GlobalState (GlobalState title 3)]
    (run-level global)))

(test
  arena-lifetimes-cookbook
  (begin
    (test.assert-i64-eq (run-game) 42 "lexical arena lifetime cookbook")
    (test.assert-i64-eq
      (run-double-buffered-frames)
      28
      "double-buffered frame arenas")
    (test.assert-i64-eq
      (run-event-driven-unload)
      42
      "event-driven level unload after join")))

(define (main) : i64
  (let
    [lexical : i64 (run-game)]
    [double-buffered : i64 (run-double-buffered-frames)]
    [unloaded : i64 (run-event-driven-unload)]
    (if (and (= lexical 42) (= double-buffered 28) (= unloaded 42))
      42
      1)))