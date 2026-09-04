;; The negative twin of synth_struct_accessor: the SAME chain, with the table
;; length coming in as an argument so it can claim more slots than the table
;; holds.
;;
;; INL-3 changes nothing about that run. The struct-building body the measured
;; tier splices into `sa-value` retires no bounds check: the accessor's
;; `sa-slots[var]` read is checked exactly as it is when the accessor stays out
;; of line, and the check that fires is the one inside the body the tier
;; copied. So the abort SITE -- the line and column of the read in
;; `sa-lookup-in`, not of the call in the wrapper -- the message, and the exit
;; status must be byte-identical to the base compiler's at the level this case
;; is pinned at; see the note below `main` for what happens at opt2 and why
;; that is not something INL-3 introduced.
;;
;; `sa-len` and the row count come in as arguments so nothing can fold the run
;; away.
(import stdlib.io)
(import stdlib.string)

(defenum SynthValue
  (Unknown)
  (Const i64 i64 i64)
  (Over))

(define sa-len : i64
  0)
(define sa-slots : (__tl_dyn-array SynthValue)
  (__tl_make-array SynthValue 64))

;; The accessor: a guarded table read that reads a four-word value out of the
;; table and hands it back through the caller's sret buffer. Reading an enum
;; element out of an array is a MATCH ON ITS TAG that rebuilds the value into a
;; frame temp -- the `alloc` run, its closing `addr_of`, the arms' stores and
;; the final `copy_bytes` into `__sret` -- which is the exact body shape the
;; multiblock gate used to refuse.
(define (sa-lookup-in [var : i64]) : SynthValue
  (if (and (>= var 0) (< var sa-len))
    (clone (array-ref sa-slots var))
    (SynthValue.Unknown)))

;; The wrapper, and the site this fixture exists for: the accessor call is the
;; first thing its ENTRY block does, and the struct it returns is rebuilt once
;; more before it leaves.
(define (sa-value [payload : i64] [bump : i64]) : SynthValue
  (let
    [found : SynthValue (sa-lookup-in payload)]
    (match found
      [(SynthValue.Const k a b) (SynthValue.Const (+ k bump) a b)]
      [(SynthValue.Unknown) (SynthValue.Unknown)]
      [(SynthValue.Over) (SynthValue.Over)])))

;; The consumer, which takes the struct BY VALUE.
(define (sa-bind [slot : i64] [value : SynthValue]) : i64
  (match value
    [(SynthValue.Unknown) 0]
    [(SynthValue.Const k a b) (+ (+ k a) (+ b slot))]
    [(SynthValue.Over) 1]))

;; The cold second reference to the accessor, so it is not a single-site callee.
(define (sa-peek [var : i64]) : i64
  (match (sa-lookup-in var)
    [(SynthValue.Const k _ _) k]
    [(SynthValue.Unknown) 0]
    [(SynthValue.Over) 2]))

;; The nested loop the whole chain hangs from: two levels, so the sites below it
;; carry a depth-2 census weight once the counts are propagated.
(define (sa-walk [rows : i64] [cols : i64]) : i64
  (let
    [acc : i64 0]
    [r : i64 0]
    (begin
      (while (< r rows)
        (let
          [c : i64 0]
          (begin
            (while (< c cols)
              (begin
                (set!
                  acc
                  (+ acc (sa-bind c (sa-value (bit-and (+ (* r 71) c) 127) r))))
                (set! c (+ c 1))))
            (set! r (+ r 1)))))
      acc)))

(define (main) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    [cold : i64 0]
    (begin
      (set! sa-len (string.>int (io.arg 1)))
      (while (< i 64)
        (begin
          (set!
            (array-ref sa-slots i)
            (if (= (% i 3) 0)
              (SynthValue.Unknown)
              (if (= (% i 3) 1)
                (SynthValue.Const (* i 3) (+ i 5) (- (* i 2) 7))
                (SynthValue.Over))))
          (set! i (+ i 1))))
      ;; `sa-len` is 128 and the table holds 64, so the walk asks for slots
      ;; past the end -- inside the body the measured tier copied into
      ;; `sa-value` at its entry site.
      (set! total (sa-walk (string.>int (io.arg 2)) 16))
      ;; The cold second references: one apiece for the accessor and for the
      ;; wrapper the tier splices it into, so no single-site band can claim
      ;; either and both keep an out-of-line body for the asm-shape gate to
      ;; read.
      (set! cold (+ (sa-peek 4) (+ (sa-peek 9) (sa-bind 1 (sa-value 4 2)))))
      ;; Never reached, and there for the same reason as in the positive twin:
      ;; the cold references keep the accessor and the wrapper off every
      ;; single-site band, so the chain the measured tier prices is the same.
      (unless (= total 0) (return 1))
      (unless (= cold 0) (return 2))
      42)))

;; ABOUT THE PINNED LEVEL. The manifest pins this case at the default build
;; level, where the located `tl_oob_abort_at` survives the splice. At
;; `--opt-level 2` the located form degrades to the bare `tl_oob_abort` -- a
;; pre-existing property of the checked tier rather than anything INL-3
;; introduced: the BASE compiler does the same to synth_wrapped_probe_abort
;; (INL-1) and synth_tail_wrapper_abort (INL-2) at that level, while a bounds
;; abort in an un-spliced body such as content_bounds_checked_abort keeps its
;; site at every level (#7448). Comments below `main` on purpose: anything
;; added above would move the line and column this case pins.