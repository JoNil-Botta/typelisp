;: A job's reference field reassigned before the job runs is what the job
;: stores: `run` relates its operand's regions through its signature, so
;: `rb` keeps `p.r` borrowed afterwards and the write conflicts (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Job
  (:lifetimes i a)
  (m (&mut i (RefBox a)))
  (v (& a i64)))

(defstruct Pair
  (l i64)
  (r i64))

(define (run [j : (Job i a)]) : unit
  (set! (deref j.m).value j.v))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    [job : (Job rb p) (Job (&mut rb) (& p.l))]
    (set! job.v (& p.r))
    (run job)
    (set! p.r 9)
    (deref rb.value)))