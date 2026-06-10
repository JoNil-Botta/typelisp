;; #2386 slice 2 guard: a register-resident nullary enum. Every variant is
;; nullary, so the whole enum is a single 8-byte tag word held in a register --
;; no stack slot, no memory store/load round-trip. This exercises the full
;; register-resident enum path: construction (the value IS the tag), match (reads
;; the tag straight from the scrutinee register), pass-by-value into a call,
;; return-by-value, and `=` -- which for a register-resident enum compares the
;; tag word structurally.
;;
;; The `eq-same` term is the load-bearing assertion: `a` and `b` are two
;; INDEPENDENT constructions of the same variant. Under the old inline-memory
;; representation each lived in its own stack slot, so `(= a b)` compared two
;; distinct slot pointers and reported them UNEQUAL (eq-same would be 0, total
;; 31). Register-resident makes both the same tag word, so they compare equal --
;; the intended POD value-semantics -- and the program returns 42.
(defenum Dir
  (North)
  (East)
  (South)
  (West))

;; Round-trips a Dir through a call: the argument arrives in a register and the
;; result is returned in a register (no sret slot for a register-resident enum).
(define (turn-right [d : Dir]) : Dir
  (match d
    [(North) (East)]
    [(East) (South)]
    [(South) (West)]
    [(West) (North)]))

(define (code [d : Dir]) : i64
  (match d
    [(North) 1]
    [(East) 2]
    [(South) 3]
    [(West) 4]))

(define (main) : i64
  (let
    [a : Dir (South)]
    [b : Dir (South)]
    ;; structural tag compare: two separate (South) constructions are equal.
    [eq-same : i64
      (if (= a b)
        1
        0)]
    ;; distinct variants stay unequal.
    [eq-diff : i64
      (if (= (North) (West))
        1
        0)]
    ;; turn-right twice: North -> East -> South -> code 3.
    [r : Dir (turn-right (turn-right (North)))]
    (+
      (+ (* (code r) 10) (code (turn-right (West))))
      (+ (* eq-same 11) eq-diff))))