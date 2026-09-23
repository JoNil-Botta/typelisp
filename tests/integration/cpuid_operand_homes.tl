(import stdlib.io)

;; FORCING TEST for the cpuid operand setup (#7927).
;;
;; `cpuid` takes its leaf in %eax and its subleaf in %ecx, and both operand
;; homes are allocator-pooled. A probe that stays a real call receives the leaf
;; in the first argument register, which on Win64 is %rcx: loading the subleaf
;; into %rcx first destroyed the leaf, so every such probe queried leaf 0.
;;
;; The probes below recurse so they stay calls, and take the leaf from the
;; argument count so it is not a constant. Each must agree with the same query
;; spelled with literal operands, which needs no operand moves at all. Leaf 0
;; (maximum leaf and vendor string) and leaf 7 subleaf 0 (structured extended
;; features) are identical on every core of a package, so a thread migration
;; between the two queries cannot change the answer; leaf 7's EBX never equals
;; leaf 0's, which is what a clobbered leaf would return. Leaf 1 is compared
;; through EAX, ECX and EDX only: bits 31-24 of its EBX are the initial APIC id
;; of the logical processor that ran the query, which does change on migration.
(define (probe-eax [leaf : i64] [subleaf : i64] [depth : i64]) : i64
  (if (> depth 0)
    (probe-eax leaf subleaf (- depth 1))
    (cpuid-eax leaf subleaf)))

(define (probe-ebx [leaf : i64] [subleaf : i64] [depth : i64]) : i64
  (if (> depth 0)
    (probe-ebx leaf subleaf (- depth 1))
    (cpuid-ebx leaf subleaf)))

(define (probe-ecx [leaf : i64] [subleaf : i64] [depth : i64]) : i64
  (if (> depth 0)
    (probe-ecx leaf subleaf (- depth 1))
    (cpuid-ecx leaf subleaf)))

(define (probe-edx [leaf : i64] [subleaf : i64] [depth : i64]) : i64
  (if (> depth 0)
    (probe-edx leaf subleaf (- depth 1))
    (cpuid-edx leaf subleaf)))

;; Swapped parameter order puts the SUBLEAF in the first argument register.
(define (probe-ebx-swapped [subleaf : i64] [leaf : i64] [depth : i64]) : i64
  (if (> depth 0)
    (probe-ebx-swapped subleaf leaf (- depth 1))
    (cpuid-ebx leaf subleaf)))

(define (main) : i64
  (let
    [zero : i64 (- (io.arg-count) (io.arg-count))]
    [one : i64 (+ zero 1)]
    [seven : i64 (+ zero 7)]
    [max-leaf : i64 (cpuid-eax 0 0)]
    (if (< max-leaf 7)
      ;; No structured extended feature leaf: only leaf 0 can be compared.
      (if (and
        (= (probe-eax zero zero 2) (cpuid-eax 0 0))
        (= (probe-ebx zero zero 2) (cpuid-ebx 0 0))
        (= (probe-eax one zero 2) (cpuid-eax 1 0))
        (= (probe-ecx one zero 2) (cpuid-ecx 1 0))
        (= (probe-edx one zero 2) (cpuid-edx 1 0)))
        42
        2)
      (if (and
        (= (probe-eax zero zero 2) (cpuid-eax 0 0))
        (= (probe-ebx zero zero 2) (cpuid-ebx 0 0))
        (= (probe-ecx zero zero 2) (cpuid-ecx 0 0))
        (= (probe-edx zero zero 2) (cpuid-edx 0 0))
        (= (probe-eax one zero 2) (cpuid-eax 1 0))
        (= (probe-ecx one zero 2) (cpuid-ecx 1 0))
        (= (probe-edx one zero 2) (cpuid-edx 1 0))
        (not (= (probe-eax one zero 2) (cpuid-eax 0 0)))
        (= (probe-eax seven zero 2) (cpuid-eax 7 0))
        (= (probe-ebx seven zero 2) (cpuid-ebx 7 0))
        (= (probe-ecx seven zero 2) (cpuid-ecx 7 0))
        (= (probe-edx seven zero 2) (cpuid-edx 7 0))
        (= (probe-ebx-swapped zero seven 2) (cpuid-ebx 7 0))
        (not (= (probe-ebx seven zero 2) (cpuid-ebx 0 0))))
        42
        1))))