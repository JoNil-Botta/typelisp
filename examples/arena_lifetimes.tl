; Game-style arena lifetime cookbook:
; - global state lives in the default program arena
; - level state lives inside one lexical with-arena scope
; - frame-only temporaries live inside a nested lexical with-arena scope
; - one frame result is cloned out of a first-class scratch arena with with-escape
(import "stdlib/arena.tl")
(import "stdlib/profile.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(defstruct GlobalState
  (title String)
  (frame-count i64))

(defstruct LevelState
  (frames (Array String))
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
          [label : String (string-append-borrowed (& prefix) (& index-text))]
          (string-length (& label))))]
    [after : i64 (profile-alloc-live)]
    (begin
      (assert-i64-eq
        after
        before
        "per-frame with-arena should restore live bytes")
      score)))

(define (frame-summary [scratch : i64] [frame-index : i64] [score : i64]) : String
  (with-escape
    scratch
    (let
      [frame-text : String (int->string frame-index)]
      [score-text : String (int->string score)]
      [prefix : String (string-append "frame:" frame-text)]
      [suffix : String (string-append "/score:" score-text)]
      (string-append prefix suffix))))

(define (run-level [global : GlobalState]) : i64
  (with-arena
    level
    (let
      [scratch : i64 (arena-make)]
      [frame-count : i64 (struct-get global frame-count)]
      [frames : (Array String) (make-array String frame-count)]
      [frame-index : i64 0]
      [total : i64 0]
      (begin
        (while (< frame-index frame-count)
          (let
            [score : i64 (frame-temp-score frame-index)]
            [summary : String (frame-summary scratch frame-index score)]
            (begin
              (array-set! frames frame-index summary)
              (set! total (+ total score))
              (set! frame-index (+ frame-index 1)))))
        (let
          [state : LevelState (LevelState frames total)]
          [global-title : String (struct-get global title)]
          [first : String (array-ref (struct-get state frames) 0)]
          [last : String (array-ref (struct-get state frames) 2)]
          [want-title : String "arena-cookbook"]
          [want-first : String "frame:0/score:9"]
          [want-last : String "frame:2/score:9"]
          (begin
            (assert-string-eq (& global-title) (& want-title) "global title")
            (assert-string-eq (& first) (& want-first) "first frame summary")
            (assert-string-eq (& last) (& want-last) "last frame summary")
            (assert-i64-eq
              (struct-get global frame-count)
              3
              "global state should remain available inside level")
            (assert-i64-eq
              (struct-get state total-score)
              27
              "level total score")
            42))))))

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