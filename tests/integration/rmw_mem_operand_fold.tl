;; RMW-1 runtime coverage: `g = g op k` on a scalar module global lowers to the
;; adjacent `movq g(%rip),%rX / op src,%rX / movq %rX,g(%rip)` triple that the
;; backend peephole folds into ONE memory-operand instruction.
;;
;; The fold is admitted only when the loaded register is dead after the store,
;; so this fixture deliberately runs both sides of that question:
;;
;;   * `rmw-bump` updates five globals with five different ops (add/sub/or/and/
;;     xor) in both operand forms -- an immediate source and a loop-variant
;;     register source -- and reads none of them, so every triple is a fold
;;     candidate;
;;   * `rmw-bump-and-read` and `rmw-bump-and-double` return the updated counter,
;;     once and twice over. The emitter answers a read-after-write on a global
;;     cell with a RELOAD rather than by keeping the register, so the register
;;     still dies at the store and these fold too -- which makes them the rows
;;     that catch a fold with the wrong address, operand order or width, because
;;     the reload reads back exactly what the folded instruction wrote;
;;   * `rmw-bump-across-call` bumps a counter around a call, the shape whose
;;     admission depends on whether the counter's register could be one of that
;;     call's argument registers.
;;
;; Every updated value is printed, so a fold that changed a value -- or a
;; refusal that failed to happen -- moves the output. The counts come from argv
;; so no level can constant-fold the loops away, and the answer must be
;; identical at every optimization level.
(import stdlib.io)
(import stdlib.string)

(define rmw-add : i64
  0)
(define rmw-sub : i64
  0)
(define rmw-or : i64
  0)
(define rmw-and : i64
  -1)
(define rmw-xor : i64
  0)
(define rmw-hits : i64
  0)
(define rmw-side : i64
  0)
(define rmw-pair : i64
  0)

;; Five folded shapes per iteration. `rmw-add`/`rmw-sub` take an immediate and a
;; parameter; the other three take the loop counter, which is the register-source
;; form.
(define (rmw-bump [n : i64] [k : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! rmw-add (+ rmw-add 1))
          (set! rmw-sub (- rmw-sub k))
          (set! rmw-or (bit-or rmw-or i))
          (set! rmw-and (bit-and rmw-and (+ i 1024)))
          (set! rmw-xor (bit-xor rmw-xor i))
          (set! i (+ i 1))))
      unit)))

;; The updated value is the result. The emitter answers that with a RELOAD of
;; the cell rather than by keeping the register, so the register still dies at
;; the store and this folds too -- the fold and the reload together are still
;; one instruction fewer than the unfolded triple.
(define (rmw-bump-and-read [k : i64]) : i64
  (begin
    (set! rmw-hits (+ rmw-hits k))
    rmw-hits))

;; The updated value is consumed TWICE. The emitter still answers with a single
;; reload rather than by keeping the register alive across the store, so this
;; folds as well -- and that is the interaction worth running: the reload reads
;; the cell the FOLDED instruction wrote, so a fold that got the address, the
;; operand order or the operand width wrong would print a wrong number here
;; even though the folded line assembles fine. The admission list's refusals
;; are pinned exhaustively by the peephole unit tests in
;; src/compiler_backend_tests.tl, which can spell the shapes this emitter never
;; produces for a global cell.
(define (rmw-bump-and-double [k : i64]) : i64
  (begin
    (set! rmw-pair (+ rmw-pair k))
    (+ rmw-pair rmw-pair)))

(define (rmw-step [k : i64]) : i64
  (+ k 1))

;; A counter bump whose register is still allocated when the call happens.
(define (rmw-bump-across-call [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! rmw-side (+ rmw-side 3))
          (set! acc (+ acc (rmw-step i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [k : i64 (string.>int (io.arg 2))]
    [i : i64 0]
    [seen : i64 0]
    (begin
      (rmw-bump n k)
      (while (< i n)
        (begin
          (set! seen (+ seen (rmw-bump-and-read k)))
          (set! i (+ i 1))))
      (io.print-format "{} {}\n" rmw-add rmw-sub)
      (io.print-format "{} {} {}\n" rmw-or rmw-and rmw-xor)
      (io.print-format "{} {}\n" rmw-hits seen)
      (io.print-format "{} {}\n" (rmw-bump-across-call n) rmw-side)
      (io.print-format "{} {}\n" (rmw-bump-and-double k) rmw-pair)
      42)))