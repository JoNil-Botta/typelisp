;; Backend-observable SPMD lane identity in spmd-reduce (#2761).
;;
;; n = 13 gives AVX2 three full four-lane gangs plus one scalar tail lane,
;; while AVX-512 gives one full eight-lane gang plus five scalar tail lanes.
;; The value uses both public lane identity forms.
(define (reduce-lanes [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (program-count) (program-index))))

(define (main) : i64
  (bit-and (reduce-lanes 13) 0xff))