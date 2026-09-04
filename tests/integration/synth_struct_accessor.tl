;; FORCING TEST for INL-3: a callee that BUILDS A STRUCT VALUE is inlined.
;;
;; The chain is the SCCP accessor chain the packet measured, in miniature:
;;
;;   sa-walk (a doubly nested loop) -> sa-value -> sa-lookup-in
;;                                  -> sa-bind (the struct, by value)
;;
;; `sa-lookup-in` matches on a tag and builds a four-word `SynthValue`, which
;; lowering spells as a RUN of `alloc` words closed by an `addr_of` of the
;; run's last word, geps and `store_ptr`s that fill it, and a `copy_bytes` into
;; the caller's `__sret` buffer. Before INL-3 the multiblock gate's whitelist
;; refused `Alloc` and `AddrOf` outright, so every function shaped like this
;; was refused by SHAPE: no band and no measured verdict ever priced one of its
;; sites, and nothing in any trace said so.
;;
;; The calibration is the INL-1/INL-2 one. The site is `sa-value`'s ENTRY
;; block, `sa-lookup-in` is call-free, and the chain hangs from a two-level
;; loop, so the composite frequency clears the depth floor's entry relaxation
;; once the call graph's counts are propagated. `sa-peek` keeps a second, cold
;; reference to the accessor so no single-site or duplicating band can claim it
;; before the measured tier is asked.
;;
;; The exit code proves every field of the rebuilt struct: the accumulator sums
;; the tag-derived term and all three payload words of each entry, so a splice
;; that lost a storage word, mis-rebased the `addr_of`, or dropped the copy
;; into the caller's buffer cannot produce it. The shape is pinned in
;; scripts/verify-asm-shape-gates.sh, and the abort twin
;; (synth_struct_accessor_abort.tl) proves the spliced struct-building body
;; keeps its own bounds check, its own abort site and its own exit status at
;; the manifest's build level.
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
                  (+ acc (sa-bind c (sa-value (bit-and (+ (* r 7) c) 63) r))))
                (set! c (+ c 1))))
            (set! r (+ r 1)))))
      acc)))

(define (main) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    [cold : i64 0]
    (begin
      (set! sa-len 64)
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
      (set! total (sa-walk 16 16))
      ;; The cold second references: one apiece for the accessor and for the
      ;; wrapper the tier splices it into, so no single-site band can claim
      ;; either and both keep an out-of-line body for the asm-shape gate to
      ;; read.
      (set! cold (+ (sa-peek 4) (+ (sa-peek 9) (sa-bind 1 (sa-value 4 2)))))
      (unless (= total 16042) (return 1))
      (unless (= cold 37) (return 2))
      42)))