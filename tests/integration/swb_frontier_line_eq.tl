;; SWB-FIX-1 runtime coverage: the `fmt-diff-line-eq?` shape from
;; src/format_cli_core.tl. A short-circuiting range guard is followed by a call
;; that needs the frame:
;;
;;   (if (and (< i n) (< j m)) (string.eq (get a i) (get b j)) false)
;;
;; Form (a) rewrites the guard prefix into blocks that read the parameters from
;; their INCOMING argument registers, mints frame-free `__shrinkwrap_bare<N>`
;; return clones for the two bypasses and makes `__shrinkwrap_save` the single
;; entry of the framed body. The general form (SW-1/TD-1) then re-places the
;; prologue on the emitted text -- and a guard that names an incoming register
;; the saving prologue reads joins the frame-using set, which is how the
;; general Save once landed ABOVE form (a)'s frontier and left the bare clones
;; returning without popping.
;;
;; Every path is exercised: the first conjunct false, the second conjunct
;; false, both false, and the framed comparison itself with an equal and an
;; unequal pair. The indices are read out of a runtime-built table, so no call
;; site folds away, and the exit code is the bit pattern of the six results.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as swb_svec)
(import (vector.vector i64) as swb_ivec)

(define swb-cases : swb_ivec.Vec
  (swb_ivec.new))
(define swb-mask : i64
  0)
(define swb-calls : i64
  0)
(define swb-true-count : i64
  0)

(define (swb-line-eq?
  [src : (& source swb_svec.Vec)]
  [src-index : i64]
  [src-end : i64]
  [dst : (& formatted swb_svec.Vec)]
  [dst-index : i64]
  [dst-end : i64]) : bool
  (if (and (< src-index src-end) (< dst-index dst-end))
    (string.eq (swb_svec.get src src-index "") (swb_svec.get dst dst-index ""))
    false))

(define (swb-push-case! [si : i64] [se : i64] [di : i64] [de : i64]) : unit
  (begin
    (swb_ivec.push-ref! (&mut swb-cases) si)
    (swb_ivec.push-ref! (&mut swb-cases) se)
    (swb_ivec.push-ref! (&mut swb-cases) di)
    (swb_ivec.push-ref! (&mut swb-cases) de)))

(define (swb-run!
  [src : (& source swb_svec.Vec)]
  [dst : (& formatted swb_svec.Vec)]) : unit
  (let
    [i : i64 0]
    (while (< i (swb_ivec.len (& swb-cases)))
      (let
        [hit : bool
          (swb-line-eq?
            src
            (swb_ivec.get (& swb-cases) i 0)
            (swb_ivec.get (& swb-cases) (+ i 1) 0)
            dst
            (swb_ivec.get (& swb-cases) (+ i 2) 0)
            (swb_ivec.get (& swb-cases) (+ i 3) 0))]
        (begin
          (set!
            swb-mask
            (+
              (* swb-mask 2)
              (if hit
                1
                0)))
          (if hit
            (set! swb-true-count (+ swb-true-count 1))
            unit)
          (set! swb-calls (+ swb-calls 1))
          (set! i (+ i 4)))))))

(define (main) : i64
  (let
    [src : swb_svec.Vec (swb_svec.new)]
    [dst : swb_svec.Vec (swb_svec.new)]
    (begin
      (swb_svec.push-ref! (&mut src) "alpha")
      (swb_svec.push-ref! (&mut src) "beta")
      (swb_svec.push-ref! (&mut src) "gamma")
      (swb_svec.push-ref! (&mut dst) "alpha")
      (swb_svec.push-ref! (&mut dst) "delta")
      (swb_svec.push-ref! (&mut dst) "gamma")
      ;; Framed path, equal pair.
      (swb-push-case! 0 3 0 3)
      ;; Framed path, unequal pair.
      (swb-push-case! 1 3 1 3)
      ;; First conjunct false: form (a)'s first bypass.
      (swb-push-case! 3 3 0 3)
      ;; Second conjunct false: form (a)'s second bypass.
      (swb-push-case! 0 3 3 3)
      ;; Framed path again, equal pair at the tail.
      (swb-push-case! 2 3 2 3)
      ;; Both conjuncts false.
      (swb-push-case! 5 3 5 3)
      (swb-run! (& src) (& dst))
      (io.print-format "{}\n" swb-calls)
      (io.print-format "{}\n" swb-true-count)
      (io.print-format "{}\n" swb-mask)
      swb-mask)))