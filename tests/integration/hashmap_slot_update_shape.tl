(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as scalar)
(import (hashmap.hashmap String i64) as general)

;; Keep the generated value-update helpers reachable after opt2 inlining. The
;; assembly shape gate verifies that both helpers retain the slot layout and
;; update only the value field after checking the active state.
(define (scalar-update
  [map : (&mut map scalar.Map)]
  [key : i64]
  [value : i64]
  [poke : i64]) : unit
  (if (< poke 0)
    (scalar-update map key value (+ poke 1))
    (let
      [entry : (scalar.MutEntry map) (scalar.get-mut-entry map key)]
      (scalar.mut-entry-set! entry value))))

(define (general-update
  [map : (&mut map general.Map)]
  [key : String]
  [value : i64]
  [poke : i64]) : unit
  (if (< poke 0)
    (general-update map key value (+ poke 1))
    (let
      [entry : (general.MutEntry map) (general.get-mut-entry map key)]
      (general.mut-entry-set! entry value))))

(define (main) : i64
  (let
    [sm : scalar.Map (scalar.with-capacity 4)]
    [gm : general.Map (general.with-capacity 4)]
    (begin
      (scalar.insert! sm 1 10)
      (general.insert! gm "one" 10)
      (scalar-update (&mut sm) 1 30 0)
      (general-update (&mut gm) "one" 30 0)
      (if (and
        (= (scalar.get-value-or (& sm) 1 -1) 30)
        (= (general.lookup-value-or (general.get (& gm) "one") -1) 30))
        42
        1))))