;; comptime_init_callee.tl - `comptime.expr-binding-clause-init-callee`
;; reports the module-level function a binding clause's initializer calls,
;; resolved as the compiler resolves that call where the macro is called.
;; Anything else, or anything it cannot be sure of, reports "".
(import stdlib.iterator)
(import stdlib.string)
(import init_callee.probe)
(import init_callee.provider)
(import init_callee.provider as other)

;; A local whose `range` field is a function: `iterator.range` projects it.
(defstruct Ranger
  (range (-> i64 i64 i64)))

(define (subtract [first : i64] [last : i64]) : i64
  (- last first))

(define (check [got : String] [want : String]) : i64
  (if (string.eq got want)
    0
    1))

(define (reported) : i64
  (+
    ;; An import alias, the full module path, and a second alias of a user
    ;; module that also defines `range`.
    (check (probe.callee-of [x (iterator.range 0 3)]) "stdlib.iterator/range")
    (check
      (probe.callee-of [x (stdlib.iterator.range 0 3)])
      "stdlib.iterator/range")
    (check
      (probe.callee-of [x : iterator.I64Range (stdlib.iterator.range 0 3)])
      "stdlib.iterator/range")
    (check
      (probe.callee-of [x (iterator.range-inclusive 0 3)])
      "stdlib.iterator/range-inclusive")
    (check
      (probe.callee-of [x (provider.range 0 3)])
      "init_callee.provider/range")
    (check (probe.callee-of [x (other.range 0 3)]) "init_callee.provider/range")
    ;; Inside the provider, a bare call to its own `range`.
    (check (provider.bare-callee) "init_callee.provider/range")
    ;; Each clause reports its own initializer.
    (check
      (probe.callees-of [a (iterator.range 0 3)] [b 7] [c (provider.range 1 2)])
      "stdlib.iterator/range;;init_callee.provider/range;")))

(define (unreported) : i64
  (let
    [iterator : Ranger (Ranger subtract)]
    [f : (-> i64 i64 i64) subtract]
    (+
      ;; A local named like an import alias wins: these name its field.
      (check (probe.callee-of [x (iterator.range 0 3)]) "")
      (let
        [provider : i64 5]
        (check (probe.callee-of [x (provider.range provider 3)]) ""))
      ;; Not calls.
      (check (probe.callee-of [x 5]) "")
      (check (probe.callee-of [x provider.limit]) "")
      ;; A call through a local function value.
      (check (probe.callee-of [x (f 0 3)]) "")
      ;; A local or a parameter named like the provider's `range`.
      (check (provider.shadowed-callee) "")
      (check (provider.parameter-callee subtract) "")
      ;; Not a function: a struct constructor.
      (check (probe.callee-of [x (provider.Pair 1 2)]) "")
      ;; A root-module function has no module identity to report.
      (check (probe.callee-of [x (subtract 0 3)]) "")
      ;; Slash-qualified source names are rejected, not resolved.
      (check (probe.callee-of [x (stdlib.iterator/range 0 3)]) ""))))

(define (main) : i64
  (if (= (+ (reported) (unreported)) 0)
    42
    1))