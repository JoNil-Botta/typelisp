; Game-style arena lifetime cookbook:
; - global state lives in the default program arena
; - level state lives inside one lexical with-arena scope
; - frame-only temporaries live inside a nested lexical with-arena scope
; - one frame result is cloned out of a first-class scratch arena with with-escape
(import stdlib.array)
(import "stdlib/arena.tl")
(import "stdlib/profile.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(defstruct GlobalState
  (title String)
  (frame-count i64))

(defstruct LevelState
  (frame-scores (Array i64 3))
  (total-score i64))

(define (frame-temp-score [frame-index : i64]) : i64
  (let
    [before : i64 (profile-alloc-live)]
    [score : i64
      (with-arena
        frame
        (let
          [prefix : String "visible:"]
          [index-text : String (int->string frame-index)]
          [label : String (string-append (& prefix) (& index-text))]
          (string-length (& label))))]
    [after : i64 (profile-alloc-live)]
    (begin
      (assert-i64-eq
        after
        before
        "per-frame with-arena should restore live bytes")
      score)))

(define (frame-summary [scratch : Arena] [frame-index : i64] [score : i64]) : String
  (with-escape
    scratch
    (let
      [frame-text : String (int->string frame-index)]
      [score-text : String (int->string score)]
      [prefix : String (string-append "frame:" frame-text)]
      [suffix : String (string-append "/score:" score-text)]
      (string-append prefix suffix))))

(define (run-level [global : GlobalState]) : i64
  (let
    [scratch : Arena (arena-make)]
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
                  (array.array-set! frame-scores frame-index score)
                  (assert-i64-eq
                    (string-length (& summary))
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
                  (array.array-ref (struct-get state frame-scores) 0))]
              [last : String
                (frame-summary
                  scratch
                  2
                  (array.array-ref (struct-get state frame-scores) 2))]
              [want-title : String "arena-cookbook"]
              [want-first : String "frame:0/score:9"]
              [want-last : String "frame:2/score:9"]
              (begin
                (assert-string-eq
                  (& global-title)
                  (& want-title)
                  "global title")
                (assert-string-eq
                  (& first)
                  (& want-first)
                  "first frame summary")
                (assert-string-eq (& last) (& want-last) "last frame summary")
                (assert-i64-eq
                  (struct-get global frame-count)
                  3
                  "global state should remain available inside level")
                (assert-i64-eq
                  (struct-get state total-score)
                  27
                  "level total score")
                42)))))]
    (begin
      (unsafe
        (arena-destroy scratch))
      result)))

(define (run-game) : i64
  (let
    [title-prefix : String "arena"]
    [title : String (string-append title-prefix "-cookbook")]
    [global : GlobalState (GlobalState title 3)]
    (run-level global)))

(test
  arena-lifetimes-cookbook
  (assert-i64-eq (run-game) 42 "arena lifetime cookbook should pass"))

(define (main) : i64
  (run-game))