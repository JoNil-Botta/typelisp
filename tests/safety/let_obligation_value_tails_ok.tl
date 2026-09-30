;; Transparent value forms preserve the same owner on every normal result path.
(import stdlib.io)

(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(defenum Mode
  (Fast)
  (Slow))

(defstruct Pair
  (:cleanup cleanup-pair)
  (handle Handle (:owned)))

(define (returned [flag : bool]) : Handle
  (let
    [h : Handle (Handle 1)]
    (return
      (let
        [k : i64 0]
        (if flag
          (begin
            k
            (ann h : Handle))
          (unsafe
            h))))))

(define (matched [mode : Mode]) : Handle
  (let
    [h : Handle (Handle 2)]
    (return
      (match mode
        [(Mode.Fast) h]
        [(Mode.Slow)
          (begin
            0
            h)]))))

(define (as-value [flag : bool]) : Handle
  (let
    [h : Handle (Handle 3)]
    (if flag
      h
      h)))

(define (transferred [flag : bool]) : unit
  (let
    [h : Handle (Handle 4)]
    [g : Handle
      (if flag
        h
        h)]
    (cleanup-handle
      (begin
        0
        g))))

(define (one-normal-arm [flag : bool]) : Handle
  (let
    [h : Handle (Handle 5)]
    (return
      (if flag
        h
        (io.panic "no normal value")))))

(define (constructed) : unit
  (let
    [h : Handle (Handle 6)]
    [p : Pair
      (Pair
        (begin
          0
          h))]
    (cleanup-pair p)))

(define (loop-local) : unit
  (let
    [i : i64 0]
    (while (< i 2)
      (let
        [h : Handle (Handle i)]
        (begin
          (cleanup-handle
            (begin
              0
              h))
          (set! i (+ i 1))
          (continue))))))

(define (main) : i64
  (begin
    (with ([a (returned true) cleanup-handle]) unit)
    (with ([b (returned false) cleanup-handle]) unit)
    (with ([c (matched Mode.Fast) cleanup-handle]) unit)
    (with ([d (matched Mode.Slow) cleanup-handle]) unit)
    (with ([e (as-value true) cleanup-handle]) unit)
    (with ([f (as-value false) cleanup-handle]) unit)
    (with ([g (one-normal-arm true) cleanup-handle]) unit)
    (constructed)
    (transferred true)
    (transferred false)
    (loop-local)
    (+ closes 30)))