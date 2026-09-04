;; CK-5 runtime coverage: a NEST of two versioned loops whose inner guard the
;; implication table decides, beside a guard it must NOT decide whose SLOW arm
;; the caller can still reach.
;;
;; `gi-scan` is the decided nest: an outer scan loop over a string, with an
;; inner comment-skip loop nested inside it. The versioner mints the inner
;; loop's guard with the outer loop's own bound `n` on one side and the
;; container length the checks compare against on the other -- and those are one
;; value, spelled twice. The implication table decides that conjunct with the
;; empty fact, the chain is one conjunct long, and the whole guard folds; only
;; the fast clone is left. Whether it folds or not, the answer must not move.
;;
;; `gi-span` is the refused one: a caller-supplied window over a caller-supplied
;; start, which no dominating fact bounds. Its guard stays, and BOTH arms have
;; to be right. The caller reaches the slow arm on purpose by asking for a
;; window longer than the container and stopping the walk on a sentinel before
;; the end -- the checked clone runs, every check passes, and the value is the
;; one the fast clone computes for the same prefix. With the sentinel removed
;; the same call walks off the end and the first check aborts.
;;
;; Every bound comes from argv, so nothing folds at compile time, and the
;; accumulated value is printed so a wrong clone is a wrong answer.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (gi-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (gi-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; The decided nest: `#` starts a comment that the inner loop skips to the end
;; of the line, and the inner loop's versioning guard compares the outer bound
;; against the same length word the checks use.
(define (gi-scan [text : (& text str)] [out : (&mut out i64vec.Vec)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (gi-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (gi-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(gi-digit? byte)
              (let
                [value : i64 0]
                (begin
                  (while (gi-digit? (gi-byte-at text n i))
                    (begin
                      (set! value (+ (* value 10) (- (gi-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (i64vec.set-ref! out count value)
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; The refused guard, with both arms reachable: the walk stops on a zero
;; sentinel, so a window longer than the container still stays in range.
(define (gi-span [v : (& v i64vec.Vec)] [start : i64] [window : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    [live : bool true]
    (begin
      (while (and live (< i window))
        (let
          [value : i64 (array-ref (i64vec.slots v) (+ start i))]
          (begin
            (if (= value 0)
              (set! live false)
              (set! acc (+ (* acc 31) value)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [extra : i64 (string.>int (io.arg 2))]
    [sentinel : i64 (string.>int (io.arg 3))]
    [text : String (string.copy "12 34 # comment\n56 78\n90")]
    [out : i64vec.Vec (i64vec.Vec (__tl_make-array i64 16) 16)]
    [v : i64vec.Vec (i64vec.Vec (__tl_make-array i64 n) n)]
    [acc : i64 0]
    [count : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut v)) i) (+ i 1))
          (set! i (+ i 1))))
      (if (> sentinel 0)
        (set! (array-ref (i64vec.slots-mut (&mut v)) (- n sentinel)) 0)
        unit)
      (set! count (gi-scan (& text) (&mut out)))
      (set! acc count)
      (set! i 0)
      (while (< i count)
        (begin
          (set! acc (+ (* acc 7) (array-ref (i64vec.slots (& out)) i)))
          (set! i (+ i 1))))
      (set! acc (+ (* acc 11) (gi-span (& v) 0 n)))
      (set! acc (+ (* acc 13) (gi-span (& v) 0 (+ n extra))))
      (io.print-format "{}\n" acc)
      42)))