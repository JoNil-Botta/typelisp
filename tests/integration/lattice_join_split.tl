;; SROA-2. The lattice-join shape `opt-sccp-state-bind` has, and the shape the
;; aggregate word split exists for: a CLONE of a four-word enum out of a dense
;; array, a join whose every arm rebuilds that enum into a fresh temporary, and
;; an equality that reads both temporaries back. Before the split every one of
;; those temporaries stayed in memory, because the value each field holds after
;; the match is a JOIN of the per-arm stores and the old scalar replacement can
;; only forward a single dominating store.
;;
;; `bump` moves the bound index past the vector: at 0 every bind is in range and
;; the printed fold pins the join's result, so a split that dropped or reordered
;; a word changes the exit output; at 1 the very first bind writes one past the
;; end and the run must still abort with the same located message the base
;; compiler produced, from the store that the split feeds.
(import stdlib.io)
(import stdlib.string)

(defenum Lat
  (Unknown)
  (Const i64 i64 i64)
  (Over))

(defstruct LatEnv
  (slots (__tl_dyn-array Lat))
  (cap i64))

(define lat-env : LatEnv
  (LatEnv (__tl_make-array Lat 1) 1))
(define lat-changed : i64
  0)

(define (lat-fill! [env : (&mut e LatEnv)] [n : i64] [i : i64]) : unit
  (if (>= i n)
    unit
    (begin
      (set! (array-ref env.slots i) (Lat.Unknown))
      (lat-fill! env n (+ i 1)))))

;; The clone the split has to see through: a whole-enum copy out of the array.
(define (lat-lookup-in [env : (& e LatEnv)] [var : i64]) : Lat
  (if (and (>= var 0) (< var env.cap))
    (clone (array-ref env.slots var))
    (Lat.Unknown)))

;; DELIBERATELY UNGUARDED: this is the abort twin's bounds check. `merged`
;; reaches it as a call argument, which the split refuses, so the store the
;; check guards reads the buffer the join's arms wrote.
(define (lat-set-in! [env : (&mut e LatEnv)] [var : i64] [value : Lat]) : unit
  (set! (array-ref env.slots var) value))

(define (lat-eq [a : (& a Lat)] [b : (& b Lat)]) : bool
  (match a
    [(Lat.Unknown)
      (match b
        [(Lat.Unknown) true]
        [_ false])]
    [(Lat.Over)
      (match b
        [(Lat.Over) true]
        [_ false])]
    [(Lat.Const ak av aty)
      (match b
        [(Lat.Const bk bv bty)
          (and
            (= (deref ak) (deref bk))
            (= (deref av) (deref bv))
            (= (deref aty) (deref bty)))]
        [_ false])]))

(define (lat-join [old : (& o Lat)] [new : (& n Lat)]) : Lat
  (match old
    [(Lat.Unknown)
      (match new
        [(Lat.Unknown) (Lat.Unknown)]
        [(Lat.Over) (Lat.Over)]
        [(Lat.Const nk nv nty) (Lat.Const (deref nk) (deref nv) (deref nty))])]
    [(Lat.Over) (Lat.Over)]
    [(Lat.Const ok ov oty)
      (match new
        [(Lat.Unknown) (Lat.Const (deref ok) (deref ov) (deref oty))]
        [(Lat.Over) (Lat.Over)]
        [(Lat.Const nk nv nty)
          (if (and
            (= (deref ok) (deref nk))
            (= (deref ov) (deref nv))
            (= (deref oty) (deref nty)))
            (Lat.Const (deref ok) (deref ov) (deref oty))
            (Lat.Over))])]))

(define (lat-bind [var : i64] [value : Lat]) : unit
  (let
    [old : Lat (lat-lookup-in (& lat-env) var)]
    [merged : Lat (lat-join (& old) (& value))]
    (if (lat-eq (& old) (& merged))
      unit
      (begin
        (lat-set-in! (&mut lat-env) var merged)
        (set! lat-changed (+ lat-changed 1))))))

(define (lat-tag-in [env : (& e LatEnv)] [var : i64]) : i64
  (match (array-ref env.slots var)
    [(Lat.Unknown) 0]
    [(Lat.Const _ _ _) 1]
    [(Lat.Over) 2]))

(define (lat-field-in [env : (& e LatEnv)] [var : i64] [field : i64]) : i64
  (match (array-ref env.slots var)
    [(Lat.Const kind value ty)
      (cond [(= field 0) kind] [(= field 1) value] [else ty])]
    [_ 0]))

(define (lat-drive [count : i64] [bump : i64] [i : i64]) : unit
  (if (>= i count)
    unit
    (begin
      (lat-bind
        (+ i (* bump count))
        (Lat.Const (bit-and i 3) (+ (* i 7) 1) (+ i 2)))
      (lat-bind i (Lat.Const (bit-and i 3) (+ (* i 7) 1) (+ i 2)))
      (lat-bind i (Lat.Unknown))
      (if (= (bit-and i 1) 0)
        (lat-bind i (Lat.Over))
        (lat-bind i (Lat.Const 9 9 9)))
      (lat-drive count bump (+ i 1)))))

(define (lat-fold [count : i64] [i : i64] [acc : i64]) : i64
  (if (>= i count)
    acc
    (lat-fold
      count
      (+ i 1)
      (+
        (* acc 31)
        (+
          (* (lat-tag-in (& lat-env) i) 1000)
          (+
            (* (lat-field-in (& lat-env) i 0) 100)
            (+
              (* (lat-field-in (& lat-env) i 1) 10)
              (lat-field-in (& lat-env) i 2))))))))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    (begin
      (set! lat-env (LatEnv (__tl_make-array Lat count) count))
      (lat-fill! (&mut lat-env) count 0)
      (lat-drive count bump 0)
      (io.print-format "{} {}\n" (lat-fold count 0 0) lat-changed)
      42)))