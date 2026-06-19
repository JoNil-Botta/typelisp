;; compiler_backend_tests.tl - Selfhost backend test helpers split from production backend.
(import "../stdlib/io.tl")
(import "compiler_backend.tl")
(import "compiler_builtin_ids.tl")
(import "compiler_intern.tl")
(import "compiler_object_coff.tl")
(import "compiler_object_elf.tl")
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")

(define (compiler-backend-smoke-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64
  (let
    [x : i64 (inc answer)]
    (begin
      (set! x (+ x 1))
      (while (< x 45)
        (set! x (+ x 1)))
      (if (> x 44) x 0))))")

;; SysV call with more than six integer args (#750): args 7+ spill to the
;; stack. `add8` reads its last two (stack-passed) params, exercising both the
;; outgoing stack stores at the call and the incoming stack reads in the callee.
(define (compiler-backend-stack-int-args-source) : String
  "(define (add8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (+ g h))
(define (main) : i64
  (+ 0 (add8 1 2 3 4 5 6 7 8)))")

;; SysV call with more than eight f64 args (#750): xmm0..xmm7 then stack.
(define (compiler-backend-stack-f64-args-source) : String
  "(define (sum10
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]) : f64
  (+ i j))
(define (main) : i64
  (if (< (sum10 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0) 20.0) 1 0))")

;; Mixed int/f64 call that exhausts both banks and spills (#750): the integer
;; and float register indexes advance independently under System V. There are 7
;; integer args (rdi..r9 then one stacked) and 9 f64 args (xmm0..xmm7 then one
;; stacked); `mix` returns the sum of the two stack-passed args.
(define (compiler-backend-stack-mixed-args-source) : String
  "(define (mix
  [i0 : i64]
  [i1 : i64]
  [i2 : i64]
  [i3 : i64]
  [i4 : i64]
  [i5 : i64]
  [i6 : i64]
  [f0 : f64]
  [f1 : f64]
  [f2 : f64]
  [f3 : f64]
  [f4 : f64]
  [f5 : f64]
  [f6 : f64]
  [f7 : f64]
  [f8 : f64]) : i64
  (+ i6 (if (< f8 100.0) 1 0)))
(define (main) : i64
  (+ 0 (mix 1 2 3 4 5 6 7 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0)))")

;; #750 RUN-LEVEL witness source: a self-contained program that exercises all
;; three spill paths (integer, f64, and mixed) and returns 96 only when every
;; stack-passed argument arrives with the correct value and ordering. Emitted by
;; the stack-args fixture, then assembled, linked, and run by the integration
;; suite. `add8` returns g*10+h (78) so a swapped/wrong-offset int stack arg
;; changes the result; `f10check` checks the two spilled xmm-overflow floats
;; (1); `mixcheck` keeps the integer and float banks independent and returns the
;; spilled integer (17) only when the spilled float carries its value. 78+1+17.
(define (compiler-backend-stack-args-fixture-source) : String
  "(define (add8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (+ (* g 10) h))
(define (f10check
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]) : i64
  (if
    (if (< 8.5 i)
      (if (< i 9.5)
        (if (< 9.5 j) (< j 10.5) false)
        false)
      false)
    1
    0))
(define (mixcheck
  [i0 : i64]
  [i1 : i64]
  [i2 : i64]
  [i3 : i64]
  [i4 : i64]
  [i5 : i64]
  [i6 : i64]
  [f0 : f64]
  [f1 : f64]
  [f2 : f64]
  [f3 : f64]
  [f4 : f64]
  [f5 : f64]
  [f6 : f64]
  [f7 : f64]
  [f8 : f64]) : i64
  (if (if (< 8.5 f8) (< f8 9.5) false) i6 0))
(define (main) : i64
  (+
    (add8 1 2 3 4 5 6 7 8)
    (+
      (f10check 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0)
      (mixcheck 11 12 13 14 15 16 17 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0))))")

(define (compiler-backend-stack-args-fixture-emit
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-source-for-target
    (compiler-backend-stack-args-fixture-source)
    target))

(define (compiler-backend-direct-tail-call-source) : String
  "(define (finish [x : i64] [y : i64]) : i64 (+ x y))
(define (step [x : i64] [y : i64]) : i64
  (finish x y))
(define (main) : i64
  (step 20 22))")

(define (compiler-backend-direct-tail-call-stack-source) : String
  "(define (finishstack
  [n : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [acc : i64]) : i64
  (+ n (+ a (+ b (+ c (+ d (+ e (+ f acc))))))))
(define (stepstack
  [n : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [acc : i64]) : i64
  (finishstack n a b c d e acc f))
(define (main) : i64
  (stepstack 1 2 3 4 5 6 7 14))")

(define (compiler-backend-direct-tail-call-mixed-source) : String
  "(define (finishmixed
  [i0 : i64]
  [i1 : i64]
  [i2 : i64]
  [i3 : i64]
  [i4 : i64]
  [i5 : i64]
  [i6 : i64]
  [f0 : f64]
  [f1 : f64]
  [f2 : f64]
  [f3 : f64]
  [f4 : f64]
  [f5 : f64]
  [f6 : f64]
  [f7 : f64]
  [f8 : f64]) : i64
  (if (< f8 9.5) i6 0))
(define (stepmixed
  [i0 : i64]
  [i1 : i64]
  [i2 : i64]
  [i3 : i64]
  [i4 : i64]
  [i5 : i64]
  [i6 : i64]
  [f0 : f64]
  [f1 : f64]
  [f2 : f64]
  [f3 : f64]
  [f4 : f64]
  [f5 : f64]
  [f6 : f64]
  [f7 : f64]
  [f8 : f64]) : i64
  (finishmixed i0 i1 i2 i3 i4 i5 i6 f0 f1 f2 f3 f4 f5 f6 f7 f8))
(define (main) : i64
  (stepmixed 1 2 3 4 5 6 42 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0))")

(define (compiler-backend-indirect-tail-call-source) : String
  "(define (finish [x : i64]) : i64 x)
(define (step [f : (-> i64 i64)] [x : i64]) : i64
  (f x))
(define (main) : i64
  (step finish 42))")

(define (compiler-backend-indirect-tail-call-stack-source) : String
  "(define (finish6
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : i64
  (+ a (+ b (+ c (+ d (+ e f))))))
(define (step6
  [fn : (-> i64 i64 i64 i64 i64 i64 i64)]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : i64
  (fn a b c d e f))
(define (main) : i64
  (step6 finish6 1 2 3 4 5 27))")

(define (compiler-backend-raw-pointer-fixture-source) : String
  "(extern (tl_alloc [arg0 : i64]) : (MutPtr u8))

(define (write-i64 [p : (MutPtr i64)] [offset : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset p offset) value)))

(define (read-i64 [p : (MutPtr i64)] [offset : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset (ptr-cast p : (Ptr i64)) offset))))

(define (zero-address-ok?) : bool
  (unsafe
    (= (ptr->int (ptr-null : (Ptr u8))) (cast 0 : u64))))

(define (zero-roundtrip-ok?) : bool
  (ptr-null? (unsafe (int->ptr 0 : (Ptr u8)))))

(define (main) : i64
  (let
    [keep : (Array i64) (make-array i64 1)]
    (let
      [bytes : (MutPtr u8) (tl_alloc 24)]
      (let
        [items : (MutPtr i64) (unsafe (ptr-cast bytes : (MutPtr i64)))]
        (begin
          (array-set! keep 0 0)
          (write-i64 items 0 7)
          (write-i64 items 1 35)
          (write-i64 items 2 100)
          (if (ptr-null? items)
            1
            (if (zero-roundtrip-ok?)
              (if (zero-address-ok?)
                (if (= (read-i64 items 2) 100)
                  (+ (+ (read-i64 items 0) (read-i64 items 1)) (array-ref keep 0))
                  2)
                3)
              4)))))))")

(define (compiler-backend-raw-pointer-fixture-emit
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-source-for-target
    (compiler-backend-raw-pointer-fixture-source)
    target))

(define (compiler-backend-string-source) : String
  "(define greeting : String \"hi\")
(define (main) : String \"hi\")")

(define (compiler-backend-aggregate-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Shape (Nothing) (Circle i64) (Pair Point))
(define (make-point [x : i64] [y : i64]) : Point
  (Point x y))
(define (get-y [p : Point]) : i64
  (struct-get p y))
(define (make-none) : Shape
  Nothing)
(define (make-none-call) : Shape
  (Nothing))
(define (make-circle [r : i64]) : Shape
  (Circle r))
(define (make-pair [x : i64]) : Shape
  (Pair (Point x (+ x 1))))
(define (main) : i64
  (get-y (make-point 20 22)))")

(define (compiler-backend-enum-match-source) : String
  "(defenum Maybe (None) (Some i64))
(define (score [m : Maybe]) : i64
  (match m
    [None 0]
    [(Some v) v]))
(define (main) : i64
  (score (Some 42)))")

(define (compiler-backend-never-branch-register-group-source) : String
  "(extern (fail) : never)
(defenum Token (TInt i64) (TPlus) (TEnd))
(define (single [c : char]) : Token
  (if (= c #+')
    TPlus
    (begin
      (fail)
      TEnd)))
(define (main) : i64
  (match (single #+')
    [TPlus 42]
    [_ 0]))")

(define (compiler-backend-regalloc-source) : String
  "(define (calc [a : i64] [b : i64]) : i64
  (let
    [x : i64 (+ a b)]
    [y : i64 (* x 2)]
    (+ y x)))
(define (main) : i64
  (calc 10 5))")

(define (compiler-backend-callee-save-source) : String
  "(define (heavy
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : i64
  (let
    [v0 : i64 (+ a 1)]
    [v1 : i64 (+ b 2)]
    [v2 : i64 (+ c 3)]
    [v3 : i64 (+ d 4)]
    [v4 : i64 (+ e 5)]
    [v5 : i64 (+ f 6)]
    (+ v0 (+ v1 (+ v2 (+ v3 (+ v4 v5)))))))
(define (main) : i64
  (heavy 1 2 3 4 5 6))")

(define (compiler-backend-regalloc-f64-source) : String
  "(define (main) : f64
  (let
    [a : f64 1.5]
    [b : f64 2.5]
    (+ a b)))")

(define (compiler-backend-smoke-function-symbol-ok? [asm : String]) : bool
  (or
    (compiler-backend-string-contains? asm ".globl _tl_inc")
    (compiler-backend-string-contains? asm ".globl _tl_f")))

(define (compiler-backend-smoke-function-call-ok? [asm : String]) : bool
  (or
    (compiler-backend-string-contains? asm "    call _tl_inc")
    (compiler-backend-string-contains? asm "    call _tl_f")))

(define (compiler-backend-call-or-jmp-ok? [asm : String] [symbol : String]) : bool
  (or
    (compiler-backend-string-contains? asm (str-cat "    call " symbol "\n"))
    (compiler-backend-string-contains? asm (str-cat "    jmp " symbol "\n"))))

(define (compiler-backend-asm-ok? [asm : String]) : bool
  (and
    (backend-and8
      (compiler-backend-string-contains? asm ".data\n")
      (compiler-backend-string-contains? asm ".text\n")
      (compiler-backend-string-contains? asm ".globl _tl_start\n")
      (compiler-backend-string-contains? asm "_tl_start:\n")
      (compiler-backend-string-contains? asm "main:\n")
      (compiler-backend-smoke-function-symbol-ok? asm)
      (or
        (compiler-backend-string-contains? asm "_tl_inc")
        (compiler-backend-string-contains? asm "_tl_f"))
      (compiler-backend-smoke-function-call-ok? asm))
    (backend-and4
      (compiler-backend-string-contains? asm "    jge .Lf1_while_exit.2\n")
      (compiler-backend-string-contains? asm "    jle .Lf1_if_else.4\n")
      (compiler-backend-string-contains? asm "    jmp .Lf1_while_header.0\n")
      true)))

(define (compiler-backend-alloc-generic-call-text [size : i64] [reg : String]) : String
  (str-cat "    movq $" (int->string size) ", " reg "\n    call tl_alloc\n" ""))

(define (compiler-backend-alloc-fixed-call-text [size : i64]) : String
  (str-cat "    call .L_tl_alloc" (int->string size) "\n"))

(define (compiler-backend-string-contains-inline-alloc-size?
  [asm : String]
  [size : i64]) : bool
  (if (= size 16)
    (and
      (compiler-backend-string-contains?
        asm
        "    movq %fs:tl_current_arena@tpoff, %r8\n")
      (compiler-backend-string-contains? asm "    addq $16, "))
    false))

(define (compiler-backend-string-contains-alloc-size?
  [asm : String]
  [size : i64]) : bool
  (or
    (compiler-backend-string-contains?
      asm
      (compiler-backend-alloc-generic-call-text size "%rdi"))
    (compiler-backend-string-contains?
      asm
      (compiler-backend-alloc-generic-call-text size "%rcx"))
    (compiler-backend-string-contains?
      asm
      (compiler-backend-alloc-fixed-call-text size))
    (compiler-backend-string-contains-inline-alloc-size? asm size)))

(define (compiler-backend-alloc-call-count [asm : String]) : i64
  (+
    (compiler-backend-string-count asm "    call tl_alloc\n")
    (+
      (compiler-backend-string-count asm "    call .L_tl_alloc8\n")
      (+
        (compiler-backend-string-count asm "    call .L_tl_alloc16\n")
        (+
          (compiler-backend-string-count asm "    call .L_tl_alloc24\n")
          (+
            (compiler-backend-string-count asm "    call .L_tl_alloc32\n")
            (+
              (compiler-backend-string-count asm "    call .L_tl_alloc40\n")
              (+
                (compiler-backend-string-count asm "    call .L_tl_alloc48\n")
                (+
                  (compiler-backend-string-count asm "    call .L_tl_alloc56\n")
                  (compiler-backend-string-count asm "    call .L_tl_alloc64\n"))))))))))

(define (compiler-backend-source-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm) (compiler-backend-asm-ok? asm)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-object-image-source) : String
  "(extern (foreign-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\"))
(define answer : i64 40)
(define greeting : String \"hi\")
(define pi : f64 3.5)
(define (inc [x : i64]) : i64 (+ x 1))
(define (float-ok) : i64
  (if (< pi 4.0) 1 0))
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (begin
      (array-set! items 0 answer)
      (+ (foreign-call (inc (array-ref items 0))) (float-ok)))))")

(define (compiler-backend-coff-real-text-source) : String
  "(extern (foreign-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\"))
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64
  (+ (foreign-call (inc answer)) 1))")

(define (compiler-backend-object-image-shape-ok?) : bool
  (match (compiler-backend-emit-source-object-image
    (compiler-backend-object-image-source))
    [(OkCompilerBackendObject image)
      (let
        [sections : CompilerObjectSectionList (struct-get image sections)]
        [symbols : CompilerObjectSymbolList (struct-get image symbols)]
        [relocs : CompilerObjectRelocationList (struct-get image relocations)]
        (and
          (compiler-object-image-dense? image)
          (backend-and8
            (= (compiler-object-section-list-count sections) 4)
            (>
              (compiler-object-section-instr-count sections (ObjectSectionText))
              0)
            (>
              (compiler-object-section-data-count sections (ObjectSectionData))
              0)
            (>
              (compiler-object-section-data-count
                sections
                (ObjectSectionRodata))
              0)
            (compiler-object-symbol-list-contains?
              symbols
              "_tl_start"
              (ObjectSymbolExport)
              (ObjectSymbolFunction))
            (compiler-object-symbol-list-contains?
              symbols
              "main"
              (ObjectSymbolExport)
              (ObjectSymbolFunction))
            (compiler-object-symbol-list-contains?
              symbols
              "_tl_inc"
              (ObjectSymbolExport)
              (ObjectSymbolFunction))
            (compiler-object-symbol-list-contains?
              symbols
              "foreign_exact"
              (ObjectSymbolExtern)
              (ObjectSymbolFunction)))
          (backend-and8
            (compiler-object-symbol-list-contains?
              symbols
              "tl_alloc"
              (ObjectSymbolLocal)
              (ObjectSymbolRuntime))
            (compiler-object-section-contains-label?
              sections
              (ObjectSectionData)
              "_tl_answer")
            (compiler-object-section-contains-label?
              sections
              (ObjectSectionRodata)
              (compiler-backend-string-data-label "hi"))
            (compiler-object-section-contains-label?
              sections
              (ObjectSectionRodata)
              (compiler-backend-string-fat-label "hi"))
            (compiler-object-section-contains-string?
              sections
              (ObjectSectionRodata)
              "hi")
            (compiler-object-section-contains-align?
              sections
              (ObjectSectionRodata)
              8)
            (compiler-object-section-contains-i64?
              sections
              (ObjectSectionRodata)
              2)
            (compiler-object-section-contains-f64?
              sections
              (ObjectSectionRodata)
              "4.0"))
          (backend-and8
            (compiler-object-section-contains-call? sections "_tl_inc")
            (compiler-object-section-contains-call? sections "foreign_exact")
            (compiler-object-relocation-list-contains?
              relocs
              (ObjectRelocCall)
              "_tl_inc")
            (compiler-object-relocation-list-contains?
              relocs
              (ObjectRelocCall)
              "foreign_exact")
            (compiler-object-relocation-list-contains?
              relocs
              (ObjectRelocCall)
              "tl_alloc")
            (compiler-object-section-contains-bytes?
              sections
              (compiler-backend-object-bytes-from-hex "554889e5"))
            (compiler-object-section-contains-bytes?
              sections
              (compiler-backend-object-bytes-from-hex "c9c3"))
            (compiler-object-section-contains-bytes?
              sections
              (compiler-backend-object-linux-exit-bytes)))
          (compiler-object-relocation-list-contains?
            relocs
            (ObjectRelocAbs64)
            (compiler-backend-string-data-label "hi"))
          (compiler-object-relocation-list-contains?
            relocs
            (ObjectRelocRipValue)
            "_tl_answer")
          (> (compiler-object-relocation-list-count relocs) 5)))]
    [(ErrCompilerBackendObject _) false]))

(define (compiler-backend-pic-source) : String
  "(define greeting : String \"hi\")
(define (main) : i64
  (string-length greeting))")

(define (compiler-backend-pic-extern-source) : String
  "(extern (foreign-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\"))
(define (main) : i64
  (foreign-call 1))")

(define (compiler-backend-pic-output-ok?) : bool
  (match (compiler-backend-emit-source-pic-linux (compiler-backend-pic-source))
    [(OkCompilerBackendPic output)
      (let
        [asm : String (struct-get output asm)]
        [fixups : String (struct-get output fixups)]
        [data-label : String (compiler-backend-string-data-label "hi")]
        [fat-label : String (compiler-backend-string-fat-label "hi")]
        [base-label : String compiler-backend-pic-image-base-label]
        (and
          (backend-and8
            (compiler-backend-string-contains?
              asm
              (str-cat base-label ":\n" ""))
            (>= (compiler-backend-string-count asm "    .quad 0\n") 2)
            (not
              (compiler-backend-string-contains?
                asm
                (str-cat " - " base-label "\n")))
            (not
              (compiler-backend-string-contains?
                asm
                (compiler-backend-pic-quad-pattern data-label)))
            (not
              (compiler-backend-string-contains?
                asm
                (compiler-backend-pic-quad-pattern fat-label)))
            (compiler-backend-string-contains?
              fixups
              "typelisp-pic-fixups v1\n")
            (compiler-backend-string-contains? fixups "data ")
            (compiler-backend-string-contains? fixups "rodata "))
          (compiler-backend-string-contains? fixups data-label)
          (compiler-backend-string-contains? fixups fat-label)))]
    [(ErrCompilerBackendPic _) false]))

(define (compiler-backend-pic-extern-reject-ok?) : bool
  (match (compiler-backend-emit-source-pic-linux
    (compiler-backend-pic-extern-source))
    [(OkCompilerBackendPic _) false]
    [(ErrCompilerBackendPic diag)
      (compiler-backend-string-contains?
        (compiler-diagnostic-render diag)
        "backend: --pic supports only internal references")]))

(define (compiler-backend-pic-object-helper-ok?) : bool
  (and
    (=
      (compiler-backend-pic-data-record-end-offset
        (ObjectDataSymbolRva32 ".L_target")
        8)
      12)
    (string-eq (compiler-backend-pic-section-name (ObjectSectionPdata)) "pdata")
    (string-eq (compiler-backend-pic-section-name (ObjectSectionXdata)) "xdata")))

(define (compiler-backend-pic-ok?) : bool
  (and
    (compiler-backend-pic-output-ok?)
    (compiler-backend-pic-extern-reject-ok?)
    (compiler-backend-pic-object-helper-ok?)))

(define (compiler-backend-coff-renders-real-text-ok?) : bool
  (match (compiler-backend-emit-source-object-image-for-target
    (compiler-backend-coff-real-text-source)
    (BackendTargetWindows))
    [(OkCompilerBackendObject image)
      (match (compiler-object-coff-render image)
        [(OkCompilerObjectCoff obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset (ObjectSectionText))]
            [text-size : i64
              (compiler-object-coff-u32-at obj (+ text-header 16))]
            [reloc-count : i64
              (compiler-object-coff-u16-at obj (+ text-header 32))]
            (and
              (> text-size 0)
              (> reloc-count 0)
              (compiler-object-coff-contains? obj "foreign_exact")))]
        [(ErrCompilerObjectCoff _) false])]
    [(ErrCompilerBackendObject _) false]))

(define (compiler-backend-elf-renders-real-text-ok?) : bool
  (match (compiler-backend-emit-source-object-image-for-target
    (compiler-backend-coff-real-text-source)
    (BackendTargetLinux))
    [(OkCompilerBackendObject image)
      (match (compiler-object-elf-render image)
        [(OkCompilerObjectElf obj)
          (let
            [text-size : i64
              (compiler-object-elf-section-header-size-at
                obj
                image
                compiler-object-elf-section-text-index)]
            [rela-text-size : i64
              (compiler-object-elf-section-header-size-at
                obj
                image
                compiler-object-elf-section-rela-text-index)]
            (and
              (> text-size 0)
              (> rela-text-size 0)
              (= (% rela-text-size compiler-object-elf-relocation-size) 0)
              (compiler-object-elf-contains? obj "foreign_exact")))]
        [(ErrCompilerObjectElf _) false])]
    [(ErrCompilerBackendObject _) false]))

(define (compiler-backend-windows-object-manifest-resource-ok?
  [image : CompilerObjectImage]) : bool
  (let
    [sections : CompilerObjectSectionList (struct-get image sections)]
    [symbols : CompilerObjectSymbolList (struct-get image symbols)]
    [relocs : CompilerObjectRelocationList (struct-get image relocations)]
    [manifest : String compiler-backend-object-windows-utf8-manifest]
    [manifest-size : i64 (string-length manifest)]
    [manifest-label : String compiler-backend-object-windows-manifest-label]
    [rsrc-data-label : String compiler-backend-object-windows-rsrc-data-label]
    [manifest-offset : i64
      (compiler-object-coff-section-label-offset
        image
        (ObjectSectionRsrc)
        manifest-label)]
    [data-offset : i64
      (compiler-object-coff-section-label-offset
        image
        (ObjectSectionRsrc)
        rsrc-data-label)]
    (match (compiler-object-coff-render image)
      [(OkCompilerObjectCoff obj)
        (let
          [rsrc-header : i64
            (compiler-object-coff-section-header-offset (ObjectSectionRsrc))]
          [rsrc-size : i64 (compiler-object-coff-u32-at obj (+ rsrc-header 16))]
          [rsrc-ptr : i64 (compiler-object-coff-u32-at obj (+ rsrc-header 20))]
          [rsrc-reloc-ptr : i64
            (compiler-object-coff-u32-at obj (+ rsrc-header 24))]
          [rsrc-reloc-count : i64
            (compiler-object-coff-u16-at obj (+ rsrc-header 32))]
          [rsrc-flags : i64
            (compiler-object-coff-u32-at obj (+ rsrc-header 36))]
          (and
            (backend-and8
              (= rsrc-size (+ 88 manifest-size))
              (> rsrc-ptr 0)
              (= rsrc-reloc-count 1)
              (= rsrc-flags 0x40400040)
              (= manifest-size 376)
              (= data-offset 72)
              (= manifest-offset 88)
              (compiler-object-section-contains-label?
                sections
                (ObjectSectionRsrc)
                ".L_tl_rsrc_base"))
            (backend-and8
              (compiler-object-section-contains-label?
                sections
                (ObjectSectionRsrc)
                manifest-label)
              (compiler-object-symbol-list-contains?
                symbols
                manifest-label
                (ObjectSymbolLocal)
                (ObjectSymbolData))
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocAddr32Nb)
                manifest-label)
              (compiler-object-coff-reloc-entry-ok?
                obj
                rsrc-reloc-ptr
                0
                data-offset
                (compiler-object-coff-symbol-index image manifest-label)
                compiler-object-coff-reloc-amd64-addr32nb)
              (= (compiler-object-coff-u32-at obj (+ rsrc-ptr data-offset)) 0)
              (=
                (compiler-object-coff-u32-at obj (+ rsrc-ptr (+ data-offset 4)))
                manifest-size)
              (=
                (compiler-object-coff-u32-at obj (+ rsrc-ptr (+ data-offset 8)))
                0)
              (=
                (compiler-object-coff-u32-at
                  obj
                  (+ rsrc-ptr (+ data-offset 12)))
                0))
            (backend-and8
              (=
                (compiler-object-coff-u8-at obj (+ rsrc-ptr manifest-offset))
                0x3c)
              (=
                (compiler-object-coff-u8-at
                  obj
                  (+ rsrc-ptr (+ manifest-offset 1)))
                0x3f)
              (=
                (compiler-object-coff-u8-at
                  obj
                  (+ rsrc-ptr (+ manifest-offset 2)))
                0x78)
              (=
                (compiler-object-coff-u8-at
                  obj
                  (+ rsrc-ptr (+ manifest-offset 3)))
                0x6d)
              (compiler-object-coff-contains? obj "activeCodePage")
              (compiler-object-coff-contains? obj "UTF-8</activeCodePage>")
              (compiler-object-coff-contains? obj ".rsrc")
              true)))]
      [(ErrCompilerObjectCoff _) false])))

(define (compiler-backend-windows-object-entry-unwind-ok?) : bool
  (match (compiler-backend-emit-source-object-image-for-target
    "(define (main) : i64 0)"
    (BackendTargetWindows))
    [(OkCompilerBackendObject image)
      (let
        [sections : CompilerObjectSectionList (struct-get image sections)]
        [symbols : CompilerObjectSymbolList (struct-get image symbols)]
        [relocs : CompilerObjectRelocationList (struct-get image relocations)]
        [shape-ok : bool
          (and
            (compiler-object-image-dense? image)
            (backend-and8
              (= (compiler-object-section-list-count sections) 7)
              (compiler-object-symbol-list-contains?
                symbols
                "_tl_start"
                (ObjectSymbolExport)
                (ObjectSymbolFunction))
              (compiler-object-symbol-list-contains?
                symbols
                ".L_tl_start_end"
                (ObjectSymbolLocal)
                (ObjectSymbolFunction))
              (compiler-object-symbol-list-contains?
                symbols
                "ExitProcess"
                (ObjectSymbolExtern)
                (ObjectSymbolFunction))
              (compiler-object-symbol-list-contains?
                symbols
                "GetCommandLineA"
                (ObjectSymbolExtern)
                (ObjectSymbolFunction))
              (compiler-object-symbol-list-contains?
                symbols
                "__chkstk"
                (ObjectSymbolLocal)
                (ObjectSymbolRuntime))
              (compiler-object-symbol-list-contains?
                symbols
                ".L_tl_start_xdata"
                (ObjectSymbolLocal)
                (ObjectSymbolData))
              true)
            (backend-and8
              (compiler-object-section-contains-label?
                sections
                (ObjectSectionData)
                ".L_tl_argc")
              (compiler-object-section-contains-label?
                sections
                (ObjectSectionBss)
                "tl_boot_off")
              (compiler-object-section-contains-label?
                sections
                (ObjectSectionBss)
                "tl_boot_pool")
              true
              true
              true
              true
              true)
            (backend-and8
              (>=
                (compiler-object-coff-section-label-offset
                  image
                  (ObjectSectionText)
                  "tl_setup_argv")
                0)
              (>=
                (compiler-object-coff-section-label-offset
                  image
                  (ObjectSectionText)
                  ".L_tl_boot_alloc")
                0)
              (compiler-object-section-contains-label?
                sections
                (ObjectSectionPdata)
                ".L_tl_start_pdata_begin")
              (compiler-object-section-contains-label?
                sections
                (ObjectSectionXdata)
                ".L_tl_start_xdata")
              (compiler-object-symbol-list-contains?
                symbols
                ".L_tl_boot_alloc"
                (ObjectSymbolLocal)
                (ObjectSymbolRuntime))
              true
              true
              true)
            (backend-and8
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocCall)
                "tl_setup_argv")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocCall)
                "GetCommandLineA")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocCall)
                ".L_tl_boot_alloc")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocRipAddress)
                ".L_tl_argc")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocRipAddress)
                ".L_tl_argv")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocRipValue)
                "tl_boot_off")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocRipAddress)
                "tl_boot_pool")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocRipAddress)
                "tl_boot_off"))
            (backend-and8
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocCall)
                "main")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocCall)
                "ExitProcess")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocRipValue)
                ".L_tl_argc")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocRipValue)
                ".L_tl_argv")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocAddr32Nb)
                "_tl_start")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocAddr32Nb)
                ".L_tl_start_end")
              (compiler-object-relocation-list-contains?
                relocs
                (ObjectRelocAddr32Nb)
                ".L_tl_start_xdata")
              true))]
        (if (and
          shape-ok
          (compiler-backend-windows-object-manifest-resource-ok? image))
          (match (compiler-object-coff-render image)
            [(OkCompilerObjectCoff obj)
              (let
                [pdata-header : i64
                  (compiler-object-coff-section-header-offset
                    (ObjectSectionPdata))]
                [text-header : i64
                  (compiler-object-coff-section-header-offset
                    (ObjectSectionText))]
                [text-ptr : i64
                  (compiler-object-coff-u32-at obj (+ text-header 20))]
                [entry-offset : i64
                  (compiler-object-coff-section-label-offset
                    image
                    (ObjectSectionText)
                    "_tl_start")]
                [gs-clear-offset : i64 (+ text-ptr (+ entry-offset 9))]
                [xdata-header : i64
                  (compiler-object-coff-section-header-offset
                    (ObjectSectionXdata))]
                [pdata-size : i64
                  (compiler-object-coff-u32-at obj (+ pdata-header 16))]
                [pdata-relocs : i64
                  (compiler-object-coff-u16-at obj (+ pdata-header 32))]
                [xdata-size : i64
                  (compiler-object-coff-u32-at obj (+ xdata-header 16))]
                [xdata-ptr : i64
                  (compiler-object-coff-u32-at obj (+ xdata-header 20))]
                (and
                  (= pdata-size 12)
                  (= pdata-relocs 3)
                  (= xdata-size 8)
                  (= (compiler-object-coff-u8-at obj xdata-ptr) 0x01)
                  (= (compiler-object-coff-u8-at obj (+ xdata-ptr 1)) 0x04)
                  (= (compiler-object-coff-u8-at obj (+ xdata-ptr 2)) 0x01)
                  (= (compiler-object-coff-u8-at obj (+ xdata-ptr 4)) 0x04)
                  (= (compiler-object-coff-u8-at obj (+ xdata-ptr 5)) 0x42)
                  (= (compiler-object-coff-u8-at obj gs-clear-offset) 0x65)
                  (=
                    (compiler-object-coff-u8-at obj (+ gs-clear-offset 1))
                    0x48)
                  (=
                    (compiler-object-coff-u8-at obj (+ gs-clear-offset 2))
                    0xc7)))]
            [(ErrCompilerObjectCoff _) false])
          false))]
    [(ErrCompilerBackendObject _) false]))

(define (compiler-backend-implicit-main-source) : String
  "(define token-value : i64 7)")

(define (compiler-backend-implicit-main-linux-entry-ok? [asm : String]) : bool
  (backend-and8
    (compiler-backend-string-contains? asm ".globl _tl_start\n")
    (compiler-backend-string-contains? asm "_tl_start:\n")
    (compiler-backend-string-contains? asm ".globl main\n")
    (compiler-backend-string-contains? asm "main:\n")
    (compiler-backend-string-contains? asm "    call main\n")
    (compiler-backend-string-contains? asm "    xorl %eax, %eax\n")
    (compiler-backend-string-contains? asm ".text\n")
    true))

(define (compiler-backend-implicit-main-linux-no-entry-ok? [asm : String]) : bool
  (and
    (compiler-backend-string-contains? asm ".text\n")
    (not (compiler-backend-string-contains? asm ".globl _tl_start\n"))
    (not (compiler-backend-string-contains? asm "_tl_start:\n"))
    (not (compiler-backend-string-contains? asm "main:\n"))))

(define (compiler-backend-implicit-main-windows-entry-ok? [asm : String]) : bool
  (backend-and4
    (compiler-backend-string-contains? asm ".globl main\n")
    (compiler-backend-string-contains? asm "main:\n")
    (compiler-backend-string-contains? asm "    xorl %eax, %eax\n")
    (not (compiler-backend-string-contains? asm "\n_start:\n"))))

(define (compiler-backend-implicit-main-ok?) : bool
  (match (lower-compiler-source (compiler-backend-implicit-main-source))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-with-spans-for-target-and-entry
        program
        spans
        (BackendTargetLinux)
        true)
        [(OkCompilerBackend linux-entry-asm)
          (match (compiler-backend-emit-program-with-spans-for-target-and-entry
            program
            spans
            (BackendTargetLinux)
            false)
            [(OkCompilerBackend linux-no-entry-asm)
              (match (compiler-backend-emit-program-with-spans-for-target-and-entry
                program
                spans
                (BackendTargetWindows)
                true)
                [(OkCompilerBackend windows-entry-asm)
                  (and
                    (compiler-backend-implicit-main-linux-entry-ok?
                      linux-entry-asm)
                    (compiler-backend-implicit-main-linux-no-entry-ok?
                      linux-no-entry-asm)
                    (compiler-backend-implicit-main-windows-entry-ok?
                      windows-entry-asm))]
                [(ErrCompilerBackend _) false])]
            [(ErrCompilerBackend _) false])]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-string-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-string-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".L_tl_str_data_l2_13861_13991:")
        (compiler-backend-string-contains? asm ".L_tl_str_l2_13861_13991:")
        (compiler-backend-string-contains? asm "    .string \"hi\"\n")
        (compiler-backend-string-contains?
          asm
          "    .quad .L_tl_str_data_l2_13861_13991\n")
        (compiler-backend-string-contains? asm "    .quad 2\n")
        (compiler-backend-string-contains?
          asm
          "_tl_greeting:\n    .quad .L_tl_str_l2_13861_13991\n")
        (compiler-backend-string-contains?
          asm
          "    leaq .L_tl_str_l2_13861_13991(%rip), %rax\n"))]
    [(ErrCompilerBackend _) false]))

;; Backend-owned replacement for the string runtime helper emission tests
;; (#1044/#2064): non-allocating string parsing/equality still use backend
;; runtime helpers, while migrated allocating public helpers stay as ordinary
;; source-level calls instead of pulling in legacy helper bodies.
(define (compiler-backend-string-runtime-source) : String
  "(define (int->string [value : i64]) : String
  \"42\")
(define (substring [s : String] [start : i64] [len : i64]) : String
  (let
    [probe : char (string-ref s start)]
    \"x\"))
(define (string-concat [left : String] [right : String]) : String
  left)
(define (print-string [text : String]) : unit
  unit)
(define (print-str [text : String]) : unit
  (print-string text))
(define (parse-and-render [s : String]) : i64
  (+
    (if (string-eq s \"42\") 1 0)
    (+
      (string->int s)
      (+
        (string-length (int->string 42))
        (+
          (string-length (substring s 0 1))
          (string-length (string-concat s \"!\")))))))
(define (emit-stdout [s : String]) : unit
  (begin
    (print-string s)
    (print-str s)))
(define (main) : i64
  (begin
    (emit-stdout \"42\")
    (parse-and-render \"42\")))")

(define (compiler-backend-string-runtime-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-string-runtime-source))
    [(OkCompilerBackend asm)
      (let
        [ok : bool true]
        (begin
          (if (compiler-backend-string-contains? asm ".globl tl_string_eq\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains? asm "    call tl_string_eq\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains? asm ".extern tl_string_eq\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            ".globl tl_string_to_int\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains? asm "tl_string_to_int:\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            "    call tl_string_to_int\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            ".extern tl_string_to_int\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            ".globl tl_int_to_string\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            "    call tl_int_to_string\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            ".extern tl_int_to_string\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains? asm ".globl tl_substring\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains? asm "    call tl_substring\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains? asm ".extern tl_substring\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            ".globl tl_string_concat\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            "    call tl_string_concat\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            ".extern tl_string_concat\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains? asm ".globl tl_print_string\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            "    call tl_print_string\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            ".extern tl_print_string\n")
            (set! ok false)
            unit)
          (if (compiler-backend-string-contains?
            asm
            (compiler-backend-todo-marker))
            (set! ok false)
            unit)
          ok))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-shadowed-string-helpers-source) : String
  "(define (char-eq [a : char] [b : char]) : bool
  (= (cast a : i64) (cast b : i64)))
(define (string-eq [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    (if (not (= left-len right-len))
      false
      (let
        [i : i64 0]
        [same : bool true]
        (begin
          (while (if same (< i left-len) false)
            (if (char-eq (string-ref left i) (string-ref right i))
              (set! i (+ i 1))
              (set! same false)))
          same)))))
(define (string=? [left : String] [right : String]) : bool
  (string-eq left right))
(define (string-append [left : String] [right : String]) : String
  left)
(define (string->int [text : String]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [negative : bool false]
    [value : i64 0]
    (begin
      (if (if (> n 0) (char-eq (string-ref text 0) #-') false)
        (begin
          (set! negative true)
          (set! i 1))
        unit)
      (while (< i n)
        (begin
          (set! value (+ (* value 10) (- (cast (string-ref text i) : i64) 48)))
          (set! i (+ i 1))))
      (if negative
        (- 0 value)
        value))))
(define (main) : i64
  (if (if
    (string-eq \"same\" (string-append \"sa\" \"me\"))
    (if
      (not (string=? \"same\" \"different\"))
      (= (string->int \"-42\") -42)
      false)
    false)
    42
    0))")

(define (compiler-backend-shadowed-string-helpers-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-shadowed-string-helpers-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and4
          (not (compiler-backend-string-contains? asm ".globl tl_string_eq\n"))
          (not
            (compiler-backend-string-contains? asm "    call tl_string_eq\n"))
          (not (compiler-backend-string-contains? asm ".extern tl_string_eq\n"))
          (not
            (compiler-backend-string-contains? asm ".globl tl_string_to_int\n")))
        (not
          (compiler-backend-string-contains? asm "    call tl_string_to_int\n"))
        (not
          (compiler-backend-string-contains? asm ".extern tl_string_to_int\n"))
        (compiler-backend-string-contains? asm "    call _tl_string_append\n")
        (not
          (compiler-backend-string-contains? asm "    call tl_string_concat\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-print-runtime-source) : String
  "(define (int->string [value : i64]) : String
  \"3\")
(extern (runtime-print-string [arg0 : String]) : unit (:symbol \"tl_print_string\"))
(define (print-string [text : String]) : unit
  (runtime-print-string text))
(define (print-newline) : unit
  (print-string \"\\n\"))
(define (print [value : i64]) : unit
  (begin
    (print-string (int->string value))
    (print-newline)))
(define (main) : i64
  (begin
    (print 3)
    0))")

(define (compiler-backend-windows-print-runtime-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-windows-print-runtime-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm ".extern tl_print_string\n")
        (compiler-backend-string-contains? asm "    call tl_print_string\n")
        (not (compiler-backend-string-contains? asm ".globl tl_print_string\n"))
        (not (compiler-backend-string-contains? asm "\ntl_print_string:\n"))
        (not
          (compiler-backend-string-contains? asm "    call _tl_tl_print_str\n"))
        (not (compiler-backend-string-contains? asm ".extern tl_print_str\n"))
        (not (compiler-backend-string-contains? asm ".extern _write\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-print-runtime-source) : String
  "(extern (runtime-print-char [arg0 : char]) : unit (:symbol \"tl_print_char\"))
(extern (runtime-print-f64 [arg0 : f64]) : unit (:symbol \"tl_print_f64\"))
(define (main) : i64
  (begin
    (runtime-print-char #A')
    (runtime-print-f64 1.5)
    0))")

(define (compiler-backend-print-runtime-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-print-runtime-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".extern tl_print_char\n")
          (compiler-backend-string-contains? asm "    call tl_print_char\n")
          (compiler-backend-string-contains? asm ".extern tl_print_f64\n")
          (compiler-backend-string-contains? asm "    call tl_print_f64\n")
          (not (compiler-backend-string-contains? asm ".globl tl_print_char\n"))
          (not (compiler-backend-string-contains? asm "tl_print_char:\n"))
          (not (compiler-backend-string-contains? asm ".globl tl_print_f64\n"))
          (not (compiler-backend-string-contains? asm "tl_print_f64:\n")))
        (not (compiler-backend-string-contains? asm ".L_tl_print_f64_fmt:\n"))
        (not (compiler-backend-string-contains? asm "call _tl_print_char"))
        (not (compiler-backend-string-contains? asm "_tl_print_float"))
        (not (compiler-backend-string-contains? asm "call _tl_print_f64")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-print-runtime-ok?) : bool
  (and
    (compiler-backend-print-runtime-target-ok? (BackendTargetLinux))
    (compiler-backend-print-runtime-target-ok? (BackendTargetWindows))))

(define (compiler-backend-varargs-ffi-common-source [symbol : String]) : String
  (str-cat
    "(extern (tl_alloc [arg0 : i64]) : (MutPtr u8))
(extern (snprintf [buf : (MutPtr u8)] [len : i64] [fmt : (Ptr u8)] [value : ...f64]) : i32 (:symbol \""
    symbol
    "\"))

(define (write-byte! [p : (MutPtr u8)] [offset : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset p offset) (cast value : u8))))

(define (snprintf-format) : (Ptr u8)
  (let
    [fmt : (MutPtr u8) (tl_alloc 3)]
    (begin
      (write-byte! fmt 0 37)
      (write-byte! fmt 1 103)
      (write-byte! fmt 2 0)
      (unsafe (ptr-cast fmt : (Ptr u8))))))

(define (main) : i64
  (let
    [buf : (MutPtr u8) (tl_alloc 64)]
    [n : i32 (snprintf buf 64 (snprintf-format) 1.5)]
    (cast n : i64)))"))

(define (compiler-backend-varargs-ffi-linux-source) : String
  (compiler-backend-varargs-ffi-common-source "snprintf"))

(define (compiler-backend-varargs-ffi-windows-source) : String
  (compiler-backend-varargs-ffi-common-source "_snprintf"))

(define (compiler-backend-c-abi-aggregate-source) : String
  "(defstruct Color (r u8) (g u8) (b u8) (a u8))
(extern (color-make [arg0 : u8] [arg1 : u8] [arg2 : u8] [arg3 : u8]) : Color (:symbol \"tl_cabi_color_make\"))
(extern (color-use [arg0 : Color]) : i64 (:symbol \"tl_cabi_color_use\"))
(define (main) : i64
  (let
    [c : Color
      (color-make
        (cast 5 : u8)
        (cast 7 : u8)
        (cast 11 : u8)
        (cast 13 : u8))]
    [weighted : i64 (color-use c)]
    [sum : i64
      (+
        (cast (struct-get c r) : i64)
        (+
          (cast (struct-get c g) : i64)
          (+
            (cast (struct-get c b) : i64)
            (cast (struct-get c a) : i64))))]
    (if (= weighted 104)
      (if (= sum 36) 42 2)
      1)))")

(define (compiler-backend-c-abi-aggregate-linux-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-aggregate-source)
    (BackendTargetLinux))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm ".extern tl_cabi_color_make\n")
        (compiler-backend-string-contains? asm ".extern tl_cabi_color_use\n")
        (compiler-backend-string-contains? asm "    call tl_cabi_color_make\n")
        (or
          (compiler-backend-string-contains?
            asm
            (compiler-backend-alloc-generic-call-text 4 "%rdi"))
          (compiler-backend-string-contains-alloc-size? asm 8))
        (compiler-backend-string-contains? asm "    movl %eax, (%r10)\n")
        (compiler-backend-string-contains? asm "    movl (%r10), %eax\n")
        (compiler-backend-string-contains? asm "    call tl_cabi_color_use\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-c-abi-aggregate-windows-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-aggregate-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm ".extern tl_cabi_color_make\n")
        (compiler-backend-string-contains? asm ".extern tl_cabi_color_use\n")
        (compiler-backend-string-contains? asm "    call tl_cabi_color_make\n")
        (or
          (compiler-backend-string-contains?
            asm
            (compiler-backend-alloc-generic-call-text 4 "%rcx"))
          (compiler-backend-string-contains-alloc-size? asm 8))
        (compiler-backend-string-contains? asm "    movl %eax, (%r10)\n")
        (compiler-backend-string-contains? asm "    movl (%r10), %eax\n")
        (compiler-backend-string-contains? asm "    call tl_cabi_color_use\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-c-abi-aggregate-ok?) : bool
  (and
    (compiler-backend-c-abi-aggregate-linux-ok?)
    (compiler-backend-c-abi-aggregate-windows-ok?)))

(define (compiler-backend-c-abi-sret-aggregate-source) : String
  "(defstruct Wide
  (:repr c)
  (a u64)
  (b u64))
(extern (wide-make [a : u32] [b : u32] [c : u32] [d : u32] [tag : u64]) : Wide (:symbol \"tl_cabi_wide_make\"))
(extern wide-maker (:symbol \"tl_cabi_wide_make_ptr\") : (-> u32 u32 u32 u32 u64 Wide))
(define (wide-score [value : Wide]) : i64
  (+ (cast (struct-get value a) : i64) (cast (struct-get value b) : i64)))
(define (main) : i64
  (let
    [direct : Wide
      (wide-make
        (cast 1 : u32)
        (cast 2 : u32)
        (cast 3 : u32)
        (cast 4 : u32)
        (cast 10 : u64))]
    [via-ptr : Wide
      (wide-maker
        (cast 5 : u32)
        (cast 6 : u32)
        (cast 7 : u32)
        (cast 8 : u32)
        (cast 2 : u64))]
    (if (= (wide-score direct) 120)
      (if (= (wide-score via-ptr) 52) 42 2)
      1)))")

;; #2357: the Win64 sret aggregate-RETURN path (#2481) is adopted. Returning a
;; 9-16B register-group from a C function reserves a caller sret buffer (passed
;; as a scalar-pointer hidden first arg) and materializes the result back into
;; the 2-word register group (see lower-c-abi-finish-call-result). Assert the
;; sret codegen IS emitted -- both the direct call and the indirect (`call
;; *%rax`) call site -- and that nothing is rejected as unsupported.
(define (compiler-backend-c-abi-sret-aggregate-windows-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-sret-aggregate-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (backend-and4
        (backend-and4
          (compiler-backend-string-contains? asm ".extern tl_cabi_wide_make\n")
          (compiler-backend-string-contains?
            asm
            ".extern tl_cabi_wide_make_ptr\n")
          (compiler-backend-string-contains? asm "    call tl_cabi_wide_make\n")
          (compiler-backend-string-contains? asm "    call *%rax\n"))
        (not
          (compiler-backend-string-contains?
            asm
            "unsupported windows-x86_64 C aggregate ABI"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker)))
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-c-abi-byref-aggregate-arg-source) : String
  "(defstruct WideArg
  (:repr c)
  (a u64)
  (b f64))
(extern (wide-arg-score [arg : WideArg] [tag : u64]) : i64 (:symbol \"tl_cabi_wide_arg_score\"))
(extern wide-arg-scorer (:symbol \"tl_cabi_wide_arg_score_ptr\") : (-> WideArg u64 i64))
(define (main) : i64
  (let
    [direct-arg : WideArg (WideArg (cast 10 : u64) 1.5)]
    [ptr-arg : WideArg (WideArg (cast 20 : u64) 2.5)]
    [direct : i64 (wide-arg-score direct-arg (cast 7 : u64))]
    [via-ptr : i64 (wide-arg-scorer ptr-arg (cast 5 : u64))]
    (if (= direct 32)
      (if (= via-ptr 75) 42 2)
      1)))")

(define (compiler-backend-c-abi-byref-aggregate-arg-windows-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-byref-aggregate-arg-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_wide_arg_score\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_wide_arg_score_ptr\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_cabi_wide_arg_score\n")
        (compiler-backend-string-contains? asm "    call *%rax\n")
        ;; #2357: with inline-by-value aggregates (#1867) a WideArg construction
        ;; no longer heap-allocates -- the value is built in inline storage. So
        ;; the two by-value call sites need exactly the two 16-byte byref buffers
        ;; the Win64 ABI requires (down from four, when each construction also
        ;; allocated). The 16-byte buffer size is asserted just below.
        (>= (compiler-backend-alloc-call-count asm) 2)
        (compiler-backend-string-contains-alloc-size? asm 16)
        (not
          (compiler-backend-string-contains?
            asm
            "lower: unsupported windows-x86_64 C aggregate ABI"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-c-abi-win64-enum-aggregate-source) : String
  "(defenum Status (Ready) (Done) (Failed))
(defenum SmallChoice (SmallNone) (SmallSome i64))
(defenum WideChoice (WideNone) (WideSome u64 f64))
(defenum ReturnChoice (ReturnNone) (ReturnPair u64 u64))
(extern (status-pick [arg0 : Status] [arg1 : Status] [choose-second : i64]) : Status (:symbol \"tl_win64_status_pick\"))
(extern status-pick-ptr (:symbol \"tl_win64_status_pick_ptr\") : (->
  Status
  Status
  i64
  Status))
(extern (small-score [arg : SmallChoice] [bias : i64]) : i64 (:symbol \"tl_win64_small_score\"))
(extern small-scorer (:symbol \"tl_win64_small_score_ptr\") : (->
  SmallChoice
  i64
  i64))
(extern (wide-score [arg : WideChoice] [tag : u64]) : i64 (:symbol \"tl_win64_wide_score\"))
(extern wide-scorer (:symbol \"tl_win64_wide_score_ptr\") : (->
  WideChoice
  u64
  i64))
(extern (return-choice-make [a : u32] [b : u32] [tag : u64]) : ReturnChoice (:symbol \"tl_win64_return_choice_make\"))
(extern return-choice-maker (:symbol \"tl_win64_return_choice_make_ptr\") : (->
  u32
  u32
  u64
  ReturnChoice))
(define (return-score [r : ReturnChoice]) : i64
  (match r
    [ReturnNone 0]
    [(ReturnPair lo hi) (+ (cast lo : i64) (cast hi : i64))]))
(define (main) : i64
  (let
    [status-copy : (-> Status Status i64 Status) status-pick-ptr]
    [small-copy : (-> SmallChoice i64 i64) small-scorer]
    [wide-copy : (-> WideChoice u64 i64) wide-scorer]
    [return-copy : (-> u32 u32 u64 ReturnChoice) return-choice-maker]
    [picked : Status (status-pick (Ready) (Done) 1)]
    [picked-via-ptr : Status (status-copy (Ready) (Failed) 1)]
    [small-direct : i64 (small-score (SmallSome 11) 5)]
    [small-via-ptr : i64 (small-copy (SmallNone) 7)]
    [wide-direct : i64 (wide-score (WideSome (cast 20 : u64) 2.5) (cast 3 : u64))]
    [wide-via-ptr : i64 (wide-copy (WideNone) (cast 4 : u64))]
    [made : ReturnChoice
      (return-choice-make (cast 3 : u32) (cast 4 : u32) (cast 10 : u64))]
    [made-via-ptr : ReturnChoice
      (return-copy (cast 5 : u32) (cast 6 : u32) (cast 2 : u64))]
    (+ small-direct
      (+ small-via-ptr
        (+ wide-direct
          (+ wide-via-ptr
            (+ (return-score made) (return-score made-via-ptr))))))))")

(define (compiler-backend-c-abi-win64-enum-aggregate-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-win64-enum-aggregate-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm ".extern tl_win64_status_pick\n")
        (compiler-backend-string-contains? asm ".extern tl_win64_small_score\n")
        (compiler-backend-string-contains? asm ".extern tl_win64_wide_score\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_win64_return_choice_make\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_win64_status_pick\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_win64_small_score\n")
        (backend-and8
          (compiler-backend-string-contains?
            asm
            "    call tl_win64_wide_score\n")
          (compiler-backend-string-contains?
            asm
            "    call tl_win64_return_choice_make\n")
          (compiler-backend-string-contains? asm "    call *%rax\n")
          (compiler-backend-string-contains-alloc-size? asm 16)
          (compiler-backend-string-contains-alloc-size? asm 24)
          (not
            (compiler-backend-string-contains?
              asm
              "unsupported windows-x86_64 C aggregate ABI"))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))
          true)
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-c-abi-sysv-register-aggregate-arg-source) : String
  "(defstruct Inner (lo i64))
(defstruct Outer (inner Inner) (hi i64))
(defstruct Mixed (tag u64) (value f64))
(defstruct Vec2 (x f32) (y f32))
(extern (outer-use [arg0 : Outer]) : i64 (:symbol \"tl_cabi_outer_use\"))
(extern (mixed-use [arg0 : Mixed]) : i64 (:symbol \"tl_cabi_mixed_use\"))
(extern (vec2-use [arg0 : Vec2]) : i64 (:symbol \"tl_cabi_vec2_use\"))
(extern (vec2-make [seed : i64]) : Vec2 (:symbol \"tl_cabi_vec2_make\"))
(define (main) : i64
  (let
    [outer : Outer (Outer (Inner 10) 20)]
    [mixed : Mixed (Mixed (cast 7 : u64) 2.5)]
    [vec : Vec2 (Vec2 1.5 2.25)]
    [made : Vec2 (vec2-make 5)]
    (+ (outer-use outer)
       (+ (mixed-use mixed)
          (+ (vec2-use vec) (cast (struct-get made x) : i64))))))")

(define (compiler-backend-c-abi-sysv-register-aggregate-arg-linux-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-sysv-register-aggregate-arg-source)
    (BackendTargetLinux))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm ".extern tl_cabi_outer_use\n")
        (compiler-backend-string-contains? asm ".extern tl_cabi_mixed_use\n")
        (compiler-backend-string-contains? asm ".extern tl_cabi_vec2_use\n")
        (compiler-backend-string-contains? asm ".extern tl_cabi_vec2_make\n")
        (compiler-backend-string-contains? asm "    call tl_cabi_outer_use\n")
        (compiler-backend-string-contains? asm "    call tl_cabi_mixed_use\n")
        (compiler-backend-string-contains? asm "    call tl_cabi_vec2_use\n")
        (backend-and4
          (compiler-backend-string-contains? asm "    call tl_cabi_vec2_make\n")
          (compiler-backend-string-contains? asm "%xmm")
          (not
            (compiler-backend-string-contains?
              asm
              "unsupported linux-x86_64 C aggregate ABI"))
          (and
            (not
              (compiler-backend-string-contains?
                asm
                "two-register aggregate return ABI"))
            (not
              (compiler-backend-string-contains?
                asm
                (compiler-backend-todo-marker))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-c-abi-sysv-memory-aggregate-source) : String
  "(defstruct WideMem
  (:repr c)
  (a u64)
  (b u64)
  (c u64))
(defstruct InnerMem
  (:repr c)
  (lo u64)
  (hi u64))
(defstruct NestedMem
  (:repr c)
  (inner InnerMem)
  (tail u64))
(extern (wide-mem-score [arg0 : WideMem] [salt : u64]) : i64 (:symbol \"tl_cabi_wide_mem_score\"))
(extern wide-mem-scorer (:symbol \"tl_cabi_wide_mem_score_ptr\") : (->
  WideMem
  u64
  i64))
(extern (wide-mem-make [seed : u64]) : WideMem (:symbol \"tl_cabi_wide_mem_make\"))
(extern (nested-mem-score [arg0 : NestedMem]) : i64 (:symbol \"tl_cabi_nested_mem_score\"))
(define (main) : i64
  (let
    [wide : WideMem
      (WideMem (cast 1 : u64) (cast 2 : u64) (cast 3 : u64))]
    [nested : NestedMem
      (NestedMem
        (InnerMem (cast 4 : u64) (cast 5 : u64))
        (cast 6 : u64))]
    [score-copy : (-> WideMem u64 i64) wide-mem-scorer]
    [direct : i64 (wide-mem-score wide (cast 7 : u64))]
    [via-ptr : i64 (score-copy wide (cast 8 : u64))]
    [made : WideMem (wide-mem-make (cast 9 : u64))]
    (+ direct
      (+ via-ptr
        (+ (nested-mem-score nested) (cast (struct-get made a) : i64))))))")

(define (compiler-backend-c-abi-sysv-memory-aggregate-arg-linux-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-sysv-memory-aggregate-source)
    (BackendTargetLinux))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_wide_mem_score\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_wide_mem_score_ptr\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_wide_mem_make\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_nested_mem_score\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_cabi_wide_mem_score\n")
        (compiler-backend-string-contains? asm "    call *%rax\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_cabi_wide_mem_make\n")
        (backend-and8
          (compiler-backend-string-contains?
            asm
            "    call tl_cabi_nested_mem_score\n")
          (compiler-backend-string-contains? asm "    leaq 0(%rsp), %r10\n")
          (compiler-backend-string-contains? asm "    movups ")
          (not
            (compiler-backend-string-contains?
              asm
              "unsupported linux-x86_64 C aggregate ABI"))
          (not
            (compiler-backend-string-contains?
              asm
              "two-register aggregate return ABI"))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))
          true
          true))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-c-abi-sysv-two-register-return-source) : String
  "(defstruct PairI64 (:repr c) (lo i64) (hi i64))
(defstruct MixIF (:repr c) (tag u64) (value f64))
(defstruct PairF64 (:repr c) (x f64) (y f64))
(extern (pair-i64-make [seed : i64]) : PairI64 (:symbol \"tl_cabi_pair_i64_make\"))
(extern pair-i64-maker (:symbol \"tl_cabi_pair_i64_make_ptr\") : (-> i64 PairI64))
(extern (mix-if-make [seed : i64]) : MixIF (:symbol \"tl_cabi_mix_if_make\"))
(extern (pair-f64-make [seed : i64]) : PairF64 (:symbol \"tl_cabi_pair_f64_make\"))
(define (main) : i64
  (let
    [pair : PairI64 (pair-i64-make 1)]
    [pair2 : PairI64 (pair-i64-maker 4)]
    [mixed : MixIF (mix-if-make 2)]
    [floats : PairF64 (pair-f64-make 3)]
    (+ (struct-get pair lo)
      (+ (struct-get pair hi)
        (+ (struct-get pair2 lo)
          (+ (struct-get pair2 hi)
            (+ (cast (struct-get mixed tag) : i64)
              (+ (cast (struct-get mixed value) : i64)
                (+ (cast (struct-get floats x) : i64)
                   (cast (struct-get floats y) : i64))))))))))")

(define (compiler-backend-c-abi-sysv-two-register-return-linux-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-c-abi-sysv-two-register-return-source)
    (BackendTargetLinux))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_pair_i64_make\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_pair_i64_make_ptr\n")
        (compiler-backend-string-contains? asm ".extern tl_cabi_mix_if_make\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_cabi_pair_f64_make\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_cabi_pair_i64_make\n")
        (compiler-backend-string-contains? asm "    call *%rax\n")
        (backend-and8
          (compiler-backend-string-contains? asm "    movq %rdx, 8(%r11)\n")
          (compiler-backend-string-contains? asm "    movsd %xmm0, 8(%r11)\n")
          (compiler-backend-string-contains? asm "    movsd %xmm1, 8(%r11)\n")
          (not
            (compiler-backend-string-contains?
              asm
              "two-register aggregate return ABI"))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))
          true
          true
          true)
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-varargs-ffi-ok?) : bool
  (and
    (match (compiler-backend-emit-source-for-target
      (compiler-backend-varargs-ffi-linux-source)
      (BackendTargetLinux))
      [(OkCompilerBackend asm)
        (backend-and4
          (compiler-backend-string-contains? asm ".extern snprintf\n")
          (compiler-backend-string-contains? asm "    movb $1, %al\n")
          (compiler-backend-string-contains? asm "    call snprintf\n")
          true)]
      [(ErrCompilerBackend _) false])
    (match (compiler-backend-emit-source-for-target
      (compiler-backend-varargs-ffi-windows-source)
      (BackendTargetWindows))
      [(OkCompilerBackend asm)
        (backend-and4
          (compiler-backend-string-contains? asm ".extern _snprintf\n")
          (compiler-backend-string-contains? asm "    movq %xmm3, %r9\n")
          (compiler-backend-string-contains? asm "    call _snprintf\n")
          true)]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-extern-value-fnptr-source) : String
  "(extern raw-value (:symbol \"tl_test_raw_value\") : i64)
(extern raw-fn (:symbol \"tl_test_raw_fn\") : (-> i64 i64))
(extern (direct-fn [x : i64]) : i64 (:symbol \"tl_test_direct_fn\"))
(define (main) : i64
  (+ raw-value (+ (raw-fn 41) (direct-fn 1))))")

(define (compiler-backend-extern-value-fnptr-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-extern-value-fnptr-source)
    target)
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm ".extern tl_test_raw_value\n")
        (compiler-backend-string-contains? asm ".extern tl_test_raw_fn\n")
        (compiler-backend-string-contains? asm ".extern tl_test_direct_fn\n")
        (compiler-backend-string-contains? asm "    call *%rax\n")
        (compiler-backend-string-contains? asm "    call tl_test_direct_fn\n")
        (compiler-backend-string-contains? asm "tl_test_raw_fn(%rip)")
        (not
          (compiler-backend-string-contains? asm "    call tl_test_raw_fn\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-extern-value-fnptr-ok?) : bool
  (and
    (compiler-backend-extern-value-fnptr-target-ok? (BackendTargetLinux))
    (compiler-backend-extern-value-fnptr-target-ok? (BackendTargetWindows))))

(define (compiler-backend-program-argv-entry-capture-source) : String
  "(extern (fixture-strlen [arg0 : (Ptr u8)]) : i64 (:symbol \"strlen\"))
(define (main) : i64
  (let
    [argv : (Ptr (Ptr u8)) (unsafe (program-argv))]
    [raw : (Ptr u8) (unsafe (ptr-read (ptr-offset argv 1)))]
    (fixture-strlen raw)))")

(define (compiler-backend-program-argv-entry-capture-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-program-argv-entry-capture-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm "_tl_start:\n")
        (compiler-backend-string-contains? asm "    movq (%rsp), %rax\n")
        (compiler-backend-string-contains?
          asm
          "    movq %rax, .L_tl_argc(%rip)\n")
        (compiler-backend-string-contains? asm "    leaq 8(%rsp), %rax\n")
        (compiler-backend-string-contains?
          asm
          "    movq %rax, .L_tl_argv(%rip)\n")
        (compiler-backend-string-contains? asm "    call strlen\n")
        (not (compiler-backend-string-contains? asm ".L_tl_arg_count:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_arg:\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-arg-runtime-source) : String
  "(extern (runtime-arg [arg0 : i64]) : String (:symbol \".L_tl_arg\"))
(define (arg [index : i64]) : String
  (runtime-arg index))
(define (main) : i64
  (string-length (arg 0)))")

(define (compiler-backend-arg-runtime-abort-ok?) : bool
  (and
    (match (compiler-backend-emit-source-for-target
      (compiler-backend-arg-runtime-source)
      (BackendTargetLinux))
      [(OkCompilerBackend asm)
        (and
          (backend-and8
            (compiler-backend-string-contains? asm ".extern _u2eL_tl_arg\n")
            (compiler-backend-string-contains? asm "    call _u2eL_tl_arg\n")
            (not (compiler-backend-string-contains? asm ".L_tl_arg:\n"))
            (not (compiler-backend-string-contains? asm ".L_tl_abort:\n"))
            (not (compiler-backend-string-contains? asm ".L_tl_arg_oob_msg:\n"))
            (not
              (compiler-backend-string-contains? asm "    call .L_tl_abort\n"))
            (not (compiler-backend-string-contains? asm "tl_alloc:\n"))
            (compiler-backend-string-contains? asm ".L_tl_argc:\n"))
          (compiler-backend-string-contains? asm ".L_tl_argv:\n")
          (not (compiler-backend-string-contains? asm ".extern .L_tl_abort\n")))]
      [(ErrCompilerBackend _) false])
    (match (compiler-backend-emit-source-for-target
      (compiler-backend-arg-runtime-source)
      (BackendTargetWindows))
      [(OkCompilerBackend asm)
        (backend-and8
          (compiler-backend-string-contains? asm ".extern _u2eL_tl_arg\n")
          (compiler-backend-string-contains? asm "    call _u2eL_tl_arg\n")
          (not (compiler-backend-string-contains? asm ".L_tl_arg:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_abort:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_arg_oob_msg:\n"))
          (not (compiler-backend-string-contains? asm "    call .L_tl_abort\n"))
          (not (compiler-backend-string-contains? asm "    .extern _write\n"))
          (not (compiler-backend-string-contains? asm ".extern .L_tl_abort\n")))]
      [(ErrCompilerBackend _) false])))

;; Backend-owned replacement for the Rust `string-ref` emit-shape checks
;; (#1417): source-level string indexing should keep literal string data, use an
;; unsigned bounds check, call the out-of-bounds helper, and zero-extend the
;; selected byte into the char result.
(define (compiler-backend-string-ref-source) : String
  "(define sample : String \"az\")
(define (pick [i : i64]) : char (string-ref sample i))
(define (main) : i64 0)")

(define (compiler-backend-string-ref-shape-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-string-ref-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains?
            asm
            ".L_tl_str_data_l2_12961_16211:")
          (compiler-backend-string-contains? asm ".L_tl_str_l2_12961_16211:")
          (compiler-backend-string-contains? asm "    .string \"az\"\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_str_data_l2_12961_16211\n")
          (not (compiler-backend-string-contains? asm "    cmpq %r11, %rax\n"))
          (compiler-backend-string-contains? asm "    jb .Lf0_str_bounds_ok")
          (compiler-backend-string-contains? asm "    call tl_oob_abort")
          (not (compiler-backend-string-contains? asm "tl_oob_abort:\n")))
        (backend-and4
          (compiler-backend-string-contains? asm "    movq 8(%r10), %rax\n")
          (compiler-backend-string-contains? asm "(%r10)")
          (compiler-backend-string-contains? asm "movzbq")
          (not (compiler-backend-string-contains? asm "movsbq (%r10)")))
        (not
          (compiler-backend-string-contains? asm "    jl .Lf0_str_bounds_ok"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-aggregate-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-aggregate-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          ;; #1867 sret ABI: aggregate returns write the caller's sret slot
          ;; instead of arena-allocating a 16-byte object.
          (not (compiler-backend-string-contains-alloc-size? asm 16))
          (compiler-backend-string-contains?
            asm
            ".globl _tl___enum_obj_Shape_Nothing\n")
          (compiler-backend-string-contains? asm "    movq $1, (%r10)\n")
          (compiler-backend-string-contains? asm "    movq $2, (%r10)\n")
          (not (compiler-backend-string-contains? asm "    call _tl_Point\n"))
          (not (compiler-backend-string-contains? asm "    call _tl_Nothing\n"))
          (not (compiler-backend-string-contains? asm "    call _tl_Circle\n"))
          (not (compiler-backend-string-contains? asm "    call _tl_Pair\n")))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-pack-immediate-word-shape-ok?) : bool
  (match (compiler-backend-emit-pack-words
    CompilerRegAssignmentNil
    (IrValueI64 7)
    (IrValueBool true)
    "-16(%rbp)"
    "-24(%rbp)"
    false
    false
    (compiler-diagnostic-at-start "" ""))
    [(OkCompilerBackend stack-asm)
      (match (compiler-backend-emit-pack-words
        CompilerRegAssignmentNil
        (IrValueI64 9)
        (IrValueChar #A')
        "%r12"
        "%r13"
        false
        false
        (compiler-diagnostic-at-start "" ""))
        [(OkCompilerBackend reg-asm)
          (and
            (compiler-backend-string-contains?
              stack-asm
              "    movq $7, -16(%rbp)\n")
            (compiler-backend-string-contains?
              stack-asm
              "    movq $1, -24(%rbp)\n")
            (compiler-backend-string-contains? reg-asm "    movl $9, %r12d\n")
            (compiler-backend-string-contains? reg-asm "    movl $65, %r13d\n")
            (not (compiler-backend-string-contains? stack-asm "%rax"))
            (not (compiler-backend-string-contains? stack-asm "%rdx"))
            (not (compiler-backend-string-contains? reg-asm "%rax"))
            (not (compiler-backend-string-contains? reg-asm "%rdx")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

;; Backend-owned replacement for representative aggregate storage emit-shape
;; checks from the legacy backend suite (#1354/#1413).
(define (compiler-backend-aggregate-return-source) : String
  "(defenum Shape (Circle i64) (Square i64) (Nothing))
(defstruct Point (x i64) (y i64))
(define (mk-shape) : Shape (Circle 7))
(define (mk-point) : Point (Point 1 2))
(define (mk-string) : String \"hi\")
(define (main) : i64
  (+ (match (mk-shape) [(Circle r) r] [(Square s) s] [Nothing 0])
     (+ (struct-get (mk-point) y) (string-length (mk-string)))))")

(define (compiler-backend-aggregate-return-shape-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-aggregate-return-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          ;; #1867 sret ABI: struct/enum returns write the result through the
          ;; caller-provided sret slot -- no per-return arena allocation.
          (= (compiler-backend-alloc-call-count asm) 0)
          (not (compiler-backend-string-contains-alloc-size? asm 16))
          (compiler-backend-string-contains? asm "movq $7,")
          (compiler-backend-string-contains? asm "movq $1,")
          (compiler-backend-string-contains? asm "movq $2,")
          (compiler-backend-string-contains?
            asm
            ".L_tl_str_data_l2_13861_13991:")
          (compiler-backend-string-contains? asm "    .quad 2\n")
          true)
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-aggregate-global-init-source) : String
  "(defenum MaybeI64 (Some i64) (None))
(defstruct Pair (x i64) (y i64))
(defstruct Nested (label String) (choice MaybeI64))
(define (string-concat [left : String] [right : String]) : String
  left)

(define greeting : String (string-concat \"he\" \"llo\"))
(define choice : MaybeI64 (Some 8))
(define pair : Pair (Pair 10 11))
(define cells : (Array i64) (make-array i64 3))
(define nested : Nested (Nested (string-concat \"o\" \"k\") (Some 3)))

(define (main) : i64
  (+ (+ (+ (string-length greeting) (length cells))
        (+ (struct-get pair x) (struct-get pair y)))
     (+ (match choice [(Some n) n] [None 0])
        (+ (string-length (struct-get nested label))
           (match (struct-get nested choice) [(Some n) n] [None 0])))))")

(define (compiler-backend-runtime-global-shape-ok?
  [asm : String]
  [name : String]) : bool
  (let
    [symbol : String (string-append "_tl_" name)]
    [init-symbol : String (string-append "_tl___global_init_" name)]
    (and
      (backend-and4
        ;; #2386: a register-group global (e.g. `pair`) reserves 16 inline bytes;
        ;; an 8-byte handle/scalar global reserves 8. Accept either.
        (or
          (compiler-backend-string-contains?
            asm
            (str-cat "    .comm " symbol ", 8, 8\n"))
          (compiler-backend-string-contains?
            asm
            (str-cat "    .comm " symbol ", 16, 8\n")))
        (compiler-backend-string-contains?
          asm
          (str-cat "    call " init-symbol "\n"))
        (compiler-backend-string-contains?
          asm
          (str-cat "    movq %rax, " symbol "(%rip)\n"))
        (compiler-backend-string-contains? asm (str-cat init-symbol ":\n" "")))
      (or
        (compiler-backend-string-contains?
          asm
          (str-cat "    movq " symbol "(%rip), %rax\n"))
        (compiler-backend-string-contains?
          asm
          (str-cat "    movq " symbol "(%rip), %r10\n"))
        ;; #2386: a register-group global is read via its address.
        (compiler-backend-string-contains?
          asm
          (str-cat "    leaq " symbol "(%rip), %r10\n"))))))

(define (compiler-backend-aggregate-global-init-shape-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-aggregate-global-init-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-runtime-global-shape-ok? asm "greeting")
          (compiler-backend-runtime-global-shape-ok? asm "choice")
          (compiler-backend-runtime-global-shape-ok? asm "pair")
          (compiler-backend-runtime-global-shape-ok? asm "cells")
          (compiler-backend-runtime-global-shape-ok? asm "nested")
          (compiler-backend-string-contains? asm "_tl_start:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_main_keep_stack:\n    call main\n")
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker))))
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-aggregate-storage-shape-ok?) : bool
  (and
    (compiler-backend-aggregate-return-shape-ok?)
    (compiler-backend-aggregate-global-init-shape-ok?)))

;; Backend-owned replacement for closure/lambda emit-shape checks (#1415).
;; The source uses synthetic lambda lowered names because AstExprLambda lowering
;; is tracked separately; this pins the backend descriptor, adapter, and
;; indirect-call shape produced by the same IR names.
(define (compiler-backend-closure-literal-source) : String
  "(define (__tl_lambda_main_0 [x : i64]) : i64 (+ x 1))
(define (main) : i64
  (let ([f : (-> i64 i64) __tl_lambda_main_0])
    (f 41)))")

(define (compiler-backend-closure-inferred-source) : String
  "(define (__tl_lambda_main_0 [x : i64]) : i64
  (let ([y : i64 (+ x 1)])
    y))
(define (main) : i64
  (let ([f : (-> i64 i64) __tl_lambda_main_0])
    (f 41)))")

(define (compiler-backend-closure-aggregate-return-source) : String
  "(defenum Box (BoxI i64))
(defstruct Pair (x i64) (y i64))

(define (__tl_lambda_main_0) : String \"hello\")
(define (__tl_lambda_main_1) : Box (BoxI 11))
(define (__tl_lambda_main_2) : (Array i64) (make-array i64 13))
(define (__tl_lambda_main_3) : Pair (Pair 1 13))

(define (main) : i64
  (let ([mk-string : (-> String) __tl_lambda_main_0]
        [mk-enum : (-> Box) __tl_lambda_main_1]
        [mk-array : (-> (Array i64)) __tl_lambda_main_2]
        [mk-struct : (-> Pair) __tl_lambda_main_3])
    (+ (string-length (mk-string))
       (+ (match (mk-enum) [(BoxI n) n])
          (+ (array-length (mk-array))
             (struct-get (mk-struct) y))))))")

(define (compiler-backend-closure-literal-shape-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-closure-literal-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "_tl_f")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_desc___tl_lambda_main_0:\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_fn_entry___tl_lambda_main_0\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_entry___tl_lambda_main_0:\n")
          (compiler-backend-string-contains? asm "    call _tl_f")
          (compiler-backend-string-contains?
            asm
            "    leaq .L_tl_fn_desc___tl_lambda_main_0(%rip), ")
          (compiler-backend-call-or-jmp-ok? asm "*(%r11)")
          (not
            (compiler-backend-string-contains? asm "    movq (%r11), %rax\n")))
        (compiler-backend-string-contains? asm "    movq 8(%r11), %rdi\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-closure-inferred-shape-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-closure-inferred-source))
    [(OkCompilerBackend asm)
      (backend-and4
        (compiler-backend-string-contains? asm "_tl_f")
        (compiler-backend-string-contains? asm "    call _tl_f")
        (compiler-backend-call-or-jmp-ok? asm "*(%r11)")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-closure-aggregate-return-shape-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-closure-aggregate-return-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (>= (compiler-backend-string-count asm ".globl _tl_f") 4)
          (compiler-backend-string-contains? asm "_tl_f")
          (compiler-backend-string-contains? asm "    call _tl_f")
          (compiler-backend-string-contains? asm "main:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_desc___tl_lambda_main_0:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_desc___tl_lambda_main_1:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_desc___tl_lambda_main_2:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_desc___tl_lambda_main_3:\n"))
        (backend-and8
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_entry___tl_lambda_main_0:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_entry___tl_lambda_main_1:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_entry___tl_lambda_main_2:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_entry___tl_lambda_main_3:\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_fn_entry___tl_lambda_main_0\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_fn_entry___tl_lambda_main_1\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_fn_entry___tl_lambda_main_2\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_fn_entry___tl_lambda_main_3\n"))
        (backend-and8
          (compiler-backend-string-contains? asm "tl_alloc:\n")
          ;; #1867 sret ABI: only the heap-backed (Array) closure return
          ;; still allocates; Box/Pair/String returns use sret/static data.
          (>= (compiler-backend-alloc-call-count asm) 1)
          (>=
            (+
              (compiler-backend-string-count asm "    call *(%r11)\n")
              (compiler-backend-string-count asm "    jmp *(%r11)\n"))
            4)
          (not
            (compiler-backend-string-contains? asm "    movq (%r11), %rax\n"))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))
          true
          true
          true)
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-closure-emit-shape-ok?) : bool
  (and
    (compiler-backend-closure-literal-shape-ok?)
    (compiler-backend-closure-inferred-shape-ok?)
    (compiler-backend-closure-aggregate-return-shape-ok?)))

(define (compiler-backend-enum-match-ok?) : bool
  ;; #2386: `Maybe (None) (Some i64)` is a 16-byte register-resident enum, so the
  ;; tag is matched on a register-held word (no `cmpq $0, (%r10)` heap deref) and
  ;; the payload is read from word1 rather than `8(%r10)`. Those memory-shape
  ;; assertions are obsolete; what remains representation-agnostic is that the
  ;; match lowers to comparison arms and neither variant is built via a runtime
  ;; constructor call (None is an immediate tag, Some is an IrInstrPack).
  (match (compiler-backend-emit-source (compiler-backend-enum-match-source))
    [(OkCompilerBackend asm)
      (backend-and4
        (or
          (compiler-backend-string-contains? asm "_tl_score")
          (compiler-backend-string-contains? asm "_tl_f"))
        (compiler-backend-string-contains? asm "_match_arm.")
        (not (compiler-backend-string-contains? asm "    call _tl_None\n"))
        (not (compiler-backend-string-contains? asm "    call _tl_Some\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-never-branch-register-group-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-never-branch-register-group-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "main:\n")
        (not (compiler-backend-string-contains? asm "register-group")))]
    [(ErrCompilerBackend _) false]))

;; Scalar backend emission intentionally uses the stack-only plan by default for
;; cold compile speed; allocator behavior is still covered in compiler_regalloc.tl
;; and by AVX/vector backend smoke paths.
(define (compiler-backend-regalloc-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-regalloc-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (or
          (compiler-backend-string-contains? asm "_tl_calc")
          (compiler-backend-string-contains? asm "_tl_f"))
        (compiler-backend-string-contains? asm "    movq %rdi, -8(%rbp)\n")
        (compiler-backend-string-contains? asm "    movq %rsi, -16(%rbp)\n")
        (compiler-backend-string-contains? asm "    movq -32(%rbp), %rax\n")
        (compiler-backend-string-contains? asm "    imulq %r8, %rax\n")
        (not (compiler-backend-string-contains? asm "    movq %r12, -"))
        true
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-regalloc-f64-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-regalloc-f64-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm "main:\n")
        (compiler-backend-string-contains? asm "    movsd %xmm0, -8(%rbp)\n")
        (compiler-backend-string-contains? asm "    movsd -16(%rbp), %xmm0\n")
        (compiler-backend-string-contains? asm "    movsd -32(%rbp), %xmm1\n")
        (compiler-backend-string-contains? asm "    addsd %xmm1, %xmm0\n")
        (not (compiler-backend-string-contains? asm "%xmm2"))
        (not (compiler-backend-string-contains? asm "%xmm3"))
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-peephole-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%xmm2"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r13"))
        CompilerRegAssignmentNil))))

(define (compiler-backend-expanded-scalar-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r8"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r9"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-expanded-scalar-regs-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-expanded-scalar-assignments)]
    (and
      (string-eq
        (compiler-backend-emit-load-var-with-plan assignments 0 "%rax")
        "    movq %r8, %rax\n")
      (string-eq
        (compiler-backend-emit-store-var-with-plan assignments 1 "%rax")
        "    movq %rax, %r9\n")
      (string-eq
        (compiler-backend-emit-load-register "%r8" (AstTyU32))
        "    movl %r8d, %eax\n")
      (not (compiler-backend-plan-uses-callee-regs? assignments))
      (= (compiler-backend-frame-slots 2 assignments) 2))))

(define (compiler-backend-callee-save-assignments1) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    CompilerRegAssignmentNil))

(define (compiler-backend-callee-save-assignments2) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-callee-save-assignments3) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r14"))
        CompilerRegAssignmentNil))))

(define (compiler-backend-callee-save-assignments4) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r14"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 3 (CompilerRegRegister "%r15"))
          CompilerRegAssignmentNil)))))

(define (compiler-backend-callee-save-assignments5) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r14"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 3 (CompilerRegRegister "%r15"))
          (compiler-reg-assignment-cons
            (CompilerRegAssignment 4 (CompilerRegRegister "%rbx"))
            CompilerRegAssignmentNil))))))

(define (compiler-backend-callee-save-double-return-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))
    (compiler-ir-block-cons
      (compiler-ir-block
        "alt"
        (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))
      IrBlockNil)))

(define (compiler-backend-callee-save-pop-epilogue-ok?) : bool
  (let
    [one : CompilerRegAssignmentList
      (compiler-backend-callee-save-assignments1)]
    [two : CompilerRegAssignmentList
      (compiler-backend-callee-save-assignments2)]
    [three : CompilerRegAssignmentList
      (compiler-backend-callee-save-assignments3)]
    [four : CompilerRegAssignmentList
      (compiler-backend-callee-save-assignments4)]
    [five : CompilerRegAssignmentList
      (compiler-backend-callee-save-assignments5)]
    [shared : String
      (compiler-backend-return-epilogue
        "pop_shared"
        five
        1
        (compiler-backend-callee-save-double-return-blocks))]
    (and
      (backend-and8
        (string-eq
          (compiler-backend-emit-restore-callee-regs one 3)
          "    movq -32(%rbp), %r12\n")
        (string-eq
          (compiler-backend-emit-restore-callee-regs two 3)
          "    leaq -40(%rbp), %rsp\n    popq %r13\n    popq %r12\n")
        (string-eq
          (compiler-backend-emit-restore-callee-regs three 2)
          "    leaq -40(%rbp), %rsp\n    popq %r14\n    popq %r13\n    popq %r12\n")
        (string-eq
          (compiler-backend-emit-restore-callee-regs four 2)
          "    leaq -48(%rbp), %rsp\n    popq %r15\n    popq %r14\n    popq %r13\n    popq %r12\n")
        (string-eq
          (compiler-backend-emit-restore-callee-regs five 1)
          "    leaq -48(%rbp), %rsp\n    popq %rbx\n    popq %r15\n    popq %r14\n    popq %r13\n    popq %r12\n")
        (string-eq
          (compiler-backend-inline-return-tail two 3)
          "    leaq -40(%rbp), %rsp\n    popq %r13\n    popq %r12\n    leave\n    ret\n")
        (string-eq
          (compiler-backend-tail-jump-tail four 2 "_tl_next")
          "    leaq -48(%rbp), %rsp\n    popq %r15\n    popq %r14\n    popq %r13\n    popq %r12\n    leave\n    jmp _tl_next\n")
        (compiler-backend-string-contains? shared "    popq %rbx\n"))
      (compiler-backend-string-contains? shared "    leave\n    ret\n")
      (not (string-eq shared "")))))

(define (compiler-backend-peephole-register-moves-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-peephole-assignments)]
    [coalesced : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 2 (CompilerRegRegister "%r12"))
          CompilerRegAssignmentNil))]
    [casted : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 2 (CompilerRegRegister "%r13"))
          CompilerRegAssignmentNil))]
    (and
      (string-eq
        (compiler-backend-emit-load-var-with-plan assignments 0 "%r12")
        "")
      (string-eq
        (compiler-backend-emit-store-var-with-plan assignments 0 "%r12")
        "")
      (string-eq
        (compiler-backend-emit-load-f64-var-with-plan assignments 1 "%xmm0")
        "    movsd %xmm2, %xmm0\n")
      (string-eq
        (compiler-backend-emit-store-f64-var-with-plan assignments 1 "%xmm0")
        "    movsd %xmm0, %xmm2\n")
      (match (compiler-backend-emit-mov
        coalesced
        2
        (IrValueVar 0)
        (AstTyI64)
        (compiler-backend-program-index-build IrFunctionNil IrExternNil)
        8)
        [(OkCompilerBackend asm) (string-eq asm "")]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-cast
        "_tl_test"
        "entry"
        coalesced
        2
        (IrValueVar 0)
        (AstTyI64)
        (AstTyI64)
        (compiler-backend-program-index-build IrFunctionNil IrExternNil))
        [(OkCompilerBackend asm) (string-eq asm "")]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-cast
        "_tl_test"
        "entry"
        casted
        2
        (IrValueVar 0)
        (AstTyI64)
        (AstTyU64)
        (compiler-backend-program-index-build IrFunctionNil IrExternNil))
        [(OkCompilerBackend asm) (string-eq asm "    movq %r12, %r13\n")]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-cast
        "_tl_test"
        "entry"
        casted
        2
        (IrValueVar 0)
        (AstTyI32)
        (AstTyI64)
        (compiler-backend-program-index-build IrFunctionNil IrExternNil))
        [(OkCompilerBackend asm)
          (and
            (string-eq asm "    movslq %r12d, %r13\n")
            (not (compiler-backend-string-contains? asm "%rax")))]
        [(ErrCompilerBackend _) false]))))

(define (compiler-backend-direct-immediate-mov-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        CompilerRegAssignmentNil)]
    [index : CompilerBackendProgramIndex
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)]
    (and
      (match (compiler-backend-emit-mov
        assignments
        0
        (IrValueI64 0)
        (AstTyI64)
        index
        8)
        [(OkCompilerBackend asm) (string-eq asm "    xorl %r12d, %r12d\n")]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-mov
        CompilerRegAssignmentNil
        1
        (IrValueI64 7)
        (AstTyI64)
        index
        8)
        [(OkCompilerBackend asm) (string-eq asm "    movq $7, -16(%rbp)\n")]
        [(ErrCompilerBackend _) false]))))

(define (compiler-backend-register-group-test-type) : AstType
  (AstTyStruct (intern "BackendGroupTest")))

(define (compiler-backend-register-group-test-index) : CompilerBackendProgramIndex
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    (compiler-backend-program-index-build
      (compiler-ir-function-cons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          3
          (compiler-ir-block-cons
            (compiler-ir-block
              "entry"
              (compiler-ir-instr-cons
                (IrInstrPack
                  2
                  (compiler-ir-value-cons
                    (IrValueI64 1)
                    (compiler-ir-value-cons (IrValueI64 2) IrValueNil))
                  ty)
                IrInstrNil))
            IrBlockNil))
        IrFunctionNil)
      IrExternNil)))

(define (compiler-backend-register-group-mov-error-ok?
  [assignments : CompilerRegAssignmentList]
  [src : CompilerIrValue]
  [want : String]) : bool
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    [index : CompilerBackendProgramIndex
      (compiler-backend-register-group-test-index)]
    (match (compiler-backend-emit-mov assignments 1 src ty index 4)
      [(ErrCompilerBackend diag)
        (string-eq (compiler-diagnostic-message diag) want)]
      [(OkCompilerBackend _) false])))

(define (compiler-backend-register-group-call-arg-error-ok?) : bool
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    [index : CompilerBackendProgramIndex
      (compiler-backend-register-group-test-index)]
    (match (compiler-backend-emit-call-args
      (BackendTargetLinux)
      CompilerRegAssignmentNil
      (IrCallArgsOne (IrValueI64 7))
      (ast-type-cons ty AstTypeNil)
      false
      0
      0
      0
      0
      0
      (compiler-diagnostic-at-start "" "")
      index
      4)
      [(ErrCompilerBackend diag)
        (string-eq
          (compiler-diagnostic-message diag)
          "backend: register-group call argument requires var operand (#2386)")]
      [(OkCompilerBackend _) false])))

(define (compiler-backend-register-group-fail-closed-ok?) : bool
  (and
    (compiler-backend-register-group-mov-error-ok?
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        CompilerRegAssignmentNil)
      (IrValueVar 0)
      "backend: register-group var assigned scalar register home (#2386)")
    (compiler-backend-register-group-mov-error-ok?
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegSpill 16))
        CompilerRegAssignmentNil)
      (IrValueVar 0)
      "backend: register-group var assigned spill slot (#2386)")
    (compiler-backend-register-group-mov-error-ok?
      CompilerRegAssignmentNil
      (IrValueI64 7)
      "backend: register-group load requires var operand (#2386)")
    (compiler-backend-register-group-call-arg-error-ok?)))

(define (compiler-backend-ir-walker-call-use-counts-ok?) : bool
  (let
    [counts : (Array i64) (make-array i64 12)]
    (begin
      (compiler-backend-count-instr-uses
        counts
        (IrInstrCallIndirect
          0
          (IrValueVar 1)
          (IrCallArgsTwo (IrValueVar 2) (IrValueVar 3))
          (AstTyI64)))
      (compiler-backend-count-instr-uses
        counts
        (IrInstrCallIndirectC
          4
          (IrValueVar 4)
          (IrCallArgsOne (IrValueVar 5))
          (AstTyI64)))
      (compiler-backend-count-instr-uses
        counts
        (IrInstrTailCall
          "tail"
          (IrCallArgsTwo (IrValueVar 6) (IrValueVar 7))
          (AstTyI64)))
      (compiler-backend-count-instr-uses
        counts
        (IrInstrTailCallIndirect
          (IrValueVar 8)
          (IrCallArgsTwo (IrValueVar 9) (IrValueVar 10))
          (AstTyI64)))
      (and
        (backend-and8
          (= (array-ref counts 1) 1)
          (= (array-ref counts 2) 1)
          (= (array-ref counts 3) 1)
          (= (array-ref counts 4) 1)
          (= (array-ref counts 5) 1)
          (= (array-ref counts 6) 1)
          (= (array-ref counts 7) 1)
          (= (array-ref counts 8) 1))
        (= (array-ref counts 9) 1)
        (= (array-ref counts 10) 1)))))

(define (compiler-backend-ir-walker-collections-ok?) : bool
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    [values : CompilerIrValueList
      (compiler-ir-value-cons
        (IrValueFunction "walked_fn")
        (compiler-ir-value-cons
          (IrValueString "walked-string")
          (compiler-ir-value-cons (IrValueF64 "2.5") IrValueNil)))]
    [packed : CompilerBackendProgramCollections
      (compiler-backend-collect-instr-collections
        (compiler-backend-program-collections-new)
        (IrInstrPack 0 values ty))]
    [worded : CompilerBackendProgramCollections
      (compiler-backend-collect-instr-collections
        packed
        (IrInstrWord 1 (IrValueString "word-string") 0 ty))]
    (and
      (compiler-backend-string-list-contains?
        (compiler-backend-program-collections-functions worded)
        "walked_fn")
      (compiler-backend-string-list-contains?
        (compiler-backend-program-collections-strings worded)
        "walked-string")
      (compiler-backend-string-list-contains?
        (compiler-backend-program-collections-strings worded)
        "word-string")
      (compiler-backend-string-list-contains?
        (compiler-backend-program-collections-floats worded)
        "2.5"))))

(define (compiler-backend-ir-walker-program-collections-ok?) : bool
  (let
    [call-array : (Array CompilerIrValue) (make-array CompilerIrValue 2)]
    (begin
      (array-set! call-array 0 (IrValueF64 "8.5"))
      (array-set! call-array 1 (IrValueBytes "arg-bytes"))
      (let
        [instrs : CompilerIrInstrSeq
          (compiler-ir-instr-seq-from-list
            (compiler-ir-instr-cons
              (IrInstrCall
                0
                "direct"
                (IrCallArgsTwo
                  (IrValueFunction "call_fn")
                  (IrValueString "call-string"))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrCallIndirect
                  1
                  (IrValueFunction "indirect_fn")
                  (IrCallArgsArray call-array)
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrPhi
                    2
                    (compiler-ir-phi-input-cons
                      (IrValueString "phi-string")
                      "entry"
                      IrPhiInputNil)
                    (AstTyString))
                  (compiler-ir-instr-cons
                    (IrInstrReturn (IrSomeValue (IrValueBytes "return-bytes")))
                    IrInstrNil)))))]
        [blocks : CompilerIrBlockList
          (IrBlockArray
            (compiler-ir-block-seq-from-list
              (compiler-ir-block-cons (IrBlock "entry" instrs) IrBlockNil)))]
        [functions : CompilerIrFunctionList
          (IrFunctionArray
            (compiler-ir-function-seq-from-list
              (compiler-ir-function-cons
                (IrFunction "main" IrParamNil (AstTyI64) 3 blocks)
                IrFunctionNil)))]
        [globals : CompilerIrGlobalList
          (compiler-ir-global-cons
            (IrGlobal
              "global_text"
              (AstTyString)
              (IrValueString "global-string"))
            IrGlobalNil)]
        [collections : CompilerBackendProgramCollections
          (compiler-backend-collect-program-collections
            (IrProgram globals functions IrExternNil))]
        (and
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-functions collections)
            "call_fn")
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-functions collections)
            "indirect_fn")
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-strings collections)
            "global-string")
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-strings collections)
            "call-string")
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-strings collections)
            "phi-string")
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-floats collections)
            "8.5")
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-bytes collections)
            "arg-bytes")
          (compiler-backend-string-list-contains?
            (compiler-backend-program-collections-bytes collections)
            "return-bytes"))))))

(define (compiler-backend-ir-walker-group-metadata-array-ok?) : bool
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    [name : String (compiler-backend-aggregate-type-name ty)]
    [words : CompilerIrValueList
      (compiler-ir-value-cons
        (IrValueI64 1)
        (compiler-ir-value-cons (IrValueF64 "3.5") IrValueNil))]
    [instrs : CompilerIrInstrSeq
      (compiler-ir-instr-seq-from-list
        (compiler-ir-instr-cons (IrInstrPack 0 words ty) IrInstrNil))]
    [blocks : CompilerIrBlockList
      (IrBlockArray
        (compiler-ir-block-seq-from-list
          (compiler-ir-block-cons (IrBlock "entry" instrs) IrBlockNil)))]
    [functions : CompilerIrFunctionList
      (IrFunctionArray
        (compiler-ir-function-seq-from-list
          (compiler-ir-function-cons
            (IrFunction "main" IrParamNil (AstTyI64) 1 blocks)
            IrFunctionNil)))]
    [counts : StringI64Map
      (compiler-backend-collect-group-counts-functions
        (string-i64-map-with-capacity 4)
        functions)]
    [masks : StringI64Map
      (compiler-backend-collect-group-class-masks-functions
        (string-i64-map-with-capacity 4)
        functions)]
    (and
      (match (string-i64-map-get counts name)
        [(StringI64MapFound count) (= count 2)]
        [(StringI64MapMissing) false])
      (match (string-i64-map-get masks name)
        [(StringI64MapFound mask) (= mask 2)]
        [(StringI64MapMissing) false]))))

(define (compiler-backend-ir-walker-object-refs-with-plan
  [plan : CompilerBackendRuntimePlan]) : bool
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    [index : CompilerBackendProgramIndex
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)]
    [values : CompilerIrValueList
      (compiler-ir-value-cons
        (IrValueString "object-walked")
        (compiler-ir-value-cons (IrValueF64 "6.25") IrValueNil))]
    [packed : CompilerBackendObjectParts
      (compiler-backend-object-instr
        (compiler-backend-object-parts-empty)
        "main"
        "main"
        (IrInstrPack 0 values ty)
        plan
        index)]
    [worded : CompilerBackendObjectParts
      (compiler-backend-object-instr
        packed
        "main"
        "main"
        (IrInstrWord 1 (IrValueFunction "word_target") 0 ty)
        plan
        index)]
    [relocs : CompilerObjectRelocationList (struct-get worded relocations)]
    (and
      (compiler-object-relocation-list-contains?
        relocs
        (ObjectRelocRipAddress)
        (compiler-backend-string-fat-label "object-walked"))
      (compiler-object-relocation-list-contains?
        relocs
        (ObjectRelocRipValue)
        (compiler-backend-f64-label "6.25"))
      (compiler-object-relocation-list-contains?
        relocs
        (ObjectRelocRipAddress)
        (compiler-backend-closure-descriptor-label "word_target")))))

(define (compiler-backend-ir-walker-object-refs-ok?) : bool
  (match (compiler-backend-runtime-plan
    (IrProgram IrGlobalNil IrFunctionNil IrExternNil))
    [(OkBackendRuntimePlan plan)
      (compiler-backend-ir-walker-object-refs-with-plan plan)]
    [(ErrBackendRuntimePlan _) false]))

(define (compiler-backend-ir-walkers-fail-closed-ok?) : bool
  (and
    (compiler-backend-ir-walker-call-use-counts-ok?)
    (compiler-backend-ir-walker-collections-ok?)
    (compiler-backend-ir-walker-program-collections-ok?)
    (compiler-backend-ir-walker-group-metadata-array-ok?)
    (compiler-backend-ir-walker-object-refs-ok?)))

(define (compiler-backend-peephole-asm-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-peephole-assignments)]
    (match (compiler-backend-emit-binop
      (CompilerRegVarTypeNil)
      (CompilerBackendGlobalTypeNil)
      assignments
      2
      (IrBinAdd)
      (IrValueVar 0)
      (IrValueI64 5)
      (AstTyI64))
      [(OkCompilerBackend add-asm)
        (match (compiler-backend-emit-binop
          (CompilerRegVarTypeNil)
          (CompilerBackendGlobalTypeNil)
          assignments
          2
          (IrBinMul)
          (IrValueVar 0)
          (IrValueI64 3)
          (AstTyI64))
          [(OkCompilerBackend mul-asm)
            (match (compiler-backend-emit-binop
              (CompilerRegVarTypeNil)
              (CompilerBackendGlobalTypeNil)
              assignments
              2
              (IrBinShl)
              (IrValueVar 0)
              (IrValueI64 2)
              (AstTyI64))
              [(OkCompilerBackend shl-asm)
                (match (compiler-backend-emit-binop
                  (CompilerRegVarTypeNil)
                  (CompilerBackendGlobalTypeNil)
                  assignments
                  2
                  (IrBinLt)
                  (IrValueVar 0)
                  (IrValueI64 10)
                  (AstTyI64))
                  [(OkCompilerBackend cmp-asm)
                    (match (compiler-backend-emit-branch
                      assignments
                      "peephole"
                      (IrValueVar 0)
                      "then"
                      "else"
                      (CompilerBackendNoLabel))
                      [(OkCompilerBackend branch-asm)
                        (and
                          (compiler-backend-string-contains?
                            add-asm
                            "    leaq 5(%r12), %r13\n")
                          (not
                            (compiler-backend-string-contains?
                              add-asm
                              "    addq $5, %rax\n"))
                          (compiler-backend-string-contains?
                            mul-asm
                            "    imulq $3, %r12, %r13\n")
                          (not
                            (compiler-backend-string-contains?
                              mul-asm
                              "    imulq $3, %rax\n"))
                          (compiler-backend-string-contains?
                            shl-asm
                            "    shlq $2, %rax\n")
                          (not
                            (compiler-backend-string-contains?
                              shl-asm
                              "    movq $2, %r8\n"))
                          (compiler-backend-string-contains?
                            cmp-asm
                            "    cmpq $10, %rax\n    setl %al\n")
                          (compiler-backend-string-contains?
                            branch-asm
                            "    testq %r12, %r12\n    jne ")
                          (not
                            (compiler-backend-string-contains?
                              branch-asm
                              "    movq %r12, %rax\n"))
                          (not
                            (compiler-backend-string-contains?
                              branch-asm
                              "    cmpq $0, %rax\n    jne ")))]
                      [(ErrCompilerBackend _) false])]
                  [(ErrCompilerBackend _) false])]
              [(ErrCompilerBackend _) false])]
          [(ErrCompilerBackend _) false])]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-post-regalloc-peephole-ok?) : bool
  (let
    [input : String
      "label:
    movq %rax, %rax
    movq %rax, %r12
    movq %r12, %rax
    movq %rax, %r12
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    movq %r8, -24(%rbp)
    movq -24(%rbp), %r10
    movq %r8, -24(%rbp)
    movq %r9, -24(%rbp)
    movq %rax, -32(%rbp)
    movq %r8, -40(%rbp)
    movq -56(%rbp), %rax
    movq %rax, -64(%rbp)
    movq -56(%rbp), %rax
    movq %rax, -72(%rbp)
    movq $7, %rax
    movq -56(%rbp), %rax
    movq %rax, -80(%rbp)
    movq %rax, 16(%rbp)
    movq %r8, 16(%rbp)
    movq -8(%rbp), %r8
    addq %r8, %rax
    movq $0, %r8
    movq %rax, %r9
    movq %r9, %r10
"]
    [want : String
      "label:
    movq %rax, %r12
    movq %rax, -16(%rbp)
    movq %r8, -24(%rbp)
    movq %r8, %r10
    movq %r9, -24(%rbp)
    movq %rax, -32(%rbp)
    movq %r8, -40(%rbp)
    movq -56(%rbp), %rax
    movq %rax, -64(%rbp)
    movq %rax, -72(%rbp)
    movq $7, %rax
    movq -56(%rbp), %rax
    movq %rax, -80(%rbp)
    movq %rax, 16(%rbp)
    movq %r8, 16(%rbp)
    movq -8(%rbp), %r8
    addq %r8, %rax
    movq $0, %r8
    movq %rax, %r9
    movq %r9, %r10
"]
    [got : String (compiler-backend-peephole-asm input)]
    (string-eq got want)))

(define (compiler-backend-rax-forward-chain-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 0 (IrBinMul) (IrValueI64 2) (IrValueI64 3) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 1 (IrBinAdd) (IrValueVar 0) (IrValueI64 7) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueI64 11) (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 2)))
          IrInstrNil)))))

(define (compiler-backend-rax-forward-multiple-use-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 0 (IrBinAdd) (IrValueI64 1) (IrValueI64 2) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 1 (IrBinAdd) (IrValueVar 0) (IrValueI64 3) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueI64 4) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 2)))
          IrInstrNil)))))

(define (compiler-backend-emit-rax-forward-test-instrs
  [instrs : CompilerIrInstrList]
  [vars : i64]) : ResultCompilerBackend
  (let
    [blocks : CompilerIrBlockList
      (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil)]
    [use-counts : (Array i64)
      (compiler-backend-function-use-counts vars blocks)]
    (compiler-backend-emit-instrs
      (BackendTargetLinux)
      "_tl_test"
      "test"
      blocks
      "entry"
      (CompilerBackendNoLabel)
      instrs
      CompilerRegAssignmentNil
      vars
      CompilerRegVarTypeNil
      (CompilerBackendGlobalTypeNil)
      (AstTyI64)
      (compiler-backend-runtime-helper-full-plan)
      IrFunctionNil
      IrExternNil
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)
      (compiler-source-spans-empty)
      (compiler-diagnostic-at-start "" "")
      use-counts
      (text-buf-empty))))

(define (compiler-backend-rax-forwarding-ok?) : bool
  (match (compiler-backend-emit-rax-forward-test-instrs
    (compiler-backend-rax-forward-chain-instrs)
    3)
    [(OkCompilerBackend chain-asm)
      (match (compiler-backend-emit-rax-forward-test-instrs
        (compiler-backend-rax-forward-multiple-use-instrs)
        3)
        [(OkCompilerBackend multi-use-asm)
          (and
            (compiler-backend-string-contains? chain-asm "    imulq $3, %rax\n")
            (compiler-backend-string-contains? chain-asm "    addq $7, %rax\n")
            (compiler-backend-string-contains? chain-asm "    addq $11, %rax\n")
            (not
              (compiler-backend-string-contains?
                chain-asm
                "    movq %rax, -8(%rbp)\n"))
            (not
              (compiler-backend-string-contains?
                chain-asm
                "    movq %rax, -16(%rbp)\n"))
            (not
              (compiler-backend-string-contains?
                chain-asm
                "    movq %rax, -24(%rbp)\n"))
            (compiler-backend-string-contains?
              multi-use-asm
              "    movq %rax, -8(%rbp)\n"))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-binop-operand-folding-ok?) : bool
  (let
    [rhs-spill : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 1 (CompilerRegSpill -16))
        CompilerRegAssignmentNil)]
    [cmp-types : CompilerRegVarTypeList
      (compiler-reg-var-type-cons
        (CompilerRegVarType 0 (AstTyI64))
        (compiler-reg-var-type-cons
          (CompilerRegVarType 1 (AstTyI64))
          CompilerRegVarTypeNil))]
    (match (compiler-backend-emit-binop
      (CompilerRegVarTypeNil)
      (CompilerBackendGlobalTypeNil)
      rhs-spill
      2
      (IrBinAdd)
      (IrValueVar 0)
      (IrValueVar 1)
      (AstTyI64))
      [(OkCompilerBackend add-asm)
        (match (compiler-backend-emit-binop
          cmp-types
          (CompilerBackendGlobalTypeNil)
          rhs-spill
          2
          (IrBinLt)
          (IrValueVar 0)
          (IrValueVar 1)
          (AstTyBool))
          [(OkCompilerBackend cmp-asm)
            (and
              (compiler-backend-string-contains?
                add-asm
                "    addq -16(%rbp), %rax\n")
              (not
                (compiler-backend-string-contains?
                  add-asm
                  "    movq -16(%rbp), %r8\n"))
              (compiler-backend-string-contains?
                cmp-asm
                "    cmpq -16(%rbp), %rax\n    setl %al\n")
              (not
                (compiler-backend-string-contains?
                  cmp-asm
                  "    movq -16(%rbp), %r8\n"))
              (string-eq
                (compiler-backend-binop-direct-mnemonic (IrBinAnd))
                "andq")
              (string-eq
                (compiler-backend-binop-direct-mnemonic (IrBinOr))
                "orq"))]
          [(ErrCompilerBackend _) false])]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-bounds-operand-folding-ok?) : bool
  (let
    [index-reg : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        CompilerRegAssignmentNil)]
    [index-reg-length-spill : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 1 (CompilerRegSpill -16))
          CompilerRegAssignmentNil))]
    (match (compiler-backend-emit-test-instrs
      (compiler-ir-instr-cons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueI64 3) "bounds_ok")
        IrInstrNil)
      index-reg
      2)
      [(OkCompilerBackend imm-asm)
        (match (compiler-backend-emit-test-instrs
          (compiler-ir-instr-cons
            (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok")
            IrInstrNil)
          index-reg-length-spill
          3)
          [(OkCompilerBackend spill-asm)
            (and
              (compiler-backend-string-contains? imm-asm "    cmpq $3, %r12\n")
              (not
                (compiler-backend-string-contains?
                  imm-asm
                  "    movq %r12, %rax\n"))
              (not
                (compiler-backend-string-contains?
                  imm-asm
                  "    movl $3, %r11d\n"))
              (compiler-backend-string-contains?
                spill-asm
                "    cmpq -16(%rbp), %r12\n")
              (not
                (compiler-backend-string-contains?
                  spill-asm
                  "    movq %r12, %rax\n"))
              (not
                (compiler-backend-string-contains?
                  spill-asm
                  "    movq -16(%rbp), %r11\n")))]
          [(ErrCompilerBackend _) false])]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-peephole-ok?) : bool
  (and
    (compiler-backend-peephole-register-moves-ok?)
    (compiler-backend-direct-immediate-mov-ok?)
    (compiler-backend-peephole-asm-ok?)
    (compiler-backend-binop-operand-folding-ok?)
    (compiler-backend-bounds-operand-folding-ok?)
    (compiler-backend-post-regalloc-peephole-ok?)
    (compiler-backend-rax-forwarding-ok?)
    (compiler-backend-fallthrough-jump-ok?)
    (compiler-backend-branch-fallthrough-ok?)
    (compiler-backend-zero-load-ok?)
    (compiler-backend-zero-compare-ok?)
    (compiler-backend-call-return-ok?)
    (compiler-backend-global-immediate-store-ok?)
    (compiler-backend-scratch-staging-direct-shapes-ok?)))

(define (compiler-backend-fallthrough-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        0
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons (IrInstrJump "done") IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "done"
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueI64 7)))
                IrInstrNil))
            IrBlockNil)))
      IrFunctionNil)
    IrExternNil))

(define (compiler-backend-fallthrough-jump-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-fallthrough-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".Lf0_done:\n")
        (not (compiler-backend-string-contains? asm "    jmp .Lf0_done\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-branch-fallthrough-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-peephole-assignments)]
    (match (compiler-backend-emit-branch
      assignments
      "branch"
      (IrValueVar 0)
      "then"
      "else"
      (CompilerBackendSomeLabel "else"))
      [(OkCompilerBackend false-fallthrough)
        (match (compiler-backend-emit-branch
          assignments
          "branch"
          (IrValueVar 0)
          "then"
          "else"
          (CompilerBackendSomeLabel "then"))
          [(OkCompilerBackend true-fallthrough)
            (and
              (compiler-backend-string-contains?
                false-fallthrough
                "    jne .Lbranch_then\n")
              (not
                (compiler-backend-string-contains?
                  false-fallthrough
                  "    jmp .Lbranch_else\n"))
              (compiler-backend-string-contains?
                true-fallthrough
                "    je .Lbranch_else\n")
              (not
                (compiler-backend-string-contains?
                  true-fallthrough
                  "    jmp .Lbranch_then\n")))]
          [(ErrCompilerBackend _) false])]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-zero-load-ok?) : bool
  (match (compiler-backend-emit-load-value-with-plan
    CompilerRegAssignmentNil
    (IrValueI64 0)
    "%rax")
    [(OkCompilerBackend asm) (string-eq asm "    xorl %eax, %eax\n")]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-zero-compare-ok?) : bool
  (match (compiler-backend-emit-binop
    (CompilerRegVarTypeNil)
    (CompilerBackendGlobalTypeNil)
    (compiler-backend-peephole-assignments)
    2
    (IrBinEq)
    (IrValueVar 0)
    (IrValueI64 0)
    (AstTyI64))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          "    testq %rax, %rax\n    sete %al\n")
        (not (compiler-backend-string-contains? asm "    cmpq $0, %rax\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-global-immediate-store-ok?) : bool
  (compiler-backend-instr-contains?
    (IrInstrStore "g" (IrValueI64 7) (AstTyI64))
    "    movq $7, _tl_g(%rip)\n"))

(define (compiler-backend-scratch-staging-direct-shapes-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
          (compiler-reg-assignment-cons
            (CompilerRegAssignment 2 (CompilerRegRegisterPair "%r12" "%r13"))
            CompilerRegAssignmentNil)))]
    [diag : CompilerDiagnostic (compiler-diagnostic-at-start "" "")]
    (and
      (match (compiler-backend-emit-word
        assignments
        1
        (IrValueVar 2)
        0
        (AstTyI64)
        8
        diag)
        [(OkCompilerBackend asm) (string-eq asm "    movq %r12, %r13\n")]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-unop
        assignments
        1
        (IrUnNeg)
        (IrValueVar 0)
        (AstTyI64))
        [(OkCompilerBackend asm)
          (string-eq asm "    movq %r12, %r13\n    negq %r13\n")]
        [(ErrCompilerBackend _) false]))))

(define (compiler-backend-call-return-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "callee"
        IrParamNil
        (AstTyI64)
        0
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 7)))
              IrInstrNil))
          IrBlockNil))
      (compiler-ir-function-cons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          1
          (compiler-ir-block-cons
            (compiler-ir-block
              "entry"
              (compiler-ir-instr-cons
                (IrInstrCall 0 "callee" (IrCallArgsNil) (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil)))
            IrBlockNil))
        IrFunctionNil))
    IrExternNil))

(define (compiler-backend-call-return-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-call-return-program))
    [(OkCompilerBackend asm)
      (and
        (or
          (compiler-backend-string-contains? asm "    call _tl_callee")
          (compiler-backend-string-contains? asm "    call _tl_f"))
        (not
          (or
            (compiler-backend-string-contains?
              asm
              "    call _tl_callee\n    movq %rax,")
            (compiler-backend-string-contains?
              asm
              "    call _tl_f\n    movq %rax,"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-phi-same-home-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r12"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-phi-same-home-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "join"
      (compiler-ir-instr-cons
        (IrInstrPhi
          1
          (compiler-ir-phi-input-cons (IrValueVar 0) "entry" IrPhiInputNil)
          (AstTyI64))
        IrInstrNil))
    IrBlockNil))

(define (compiler-backend-phi-cycle-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "join"
      (compiler-ir-instr-cons
        (IrInstrPhi
          0
          (compiler-ir-phi-input-cons (IrValueVar 1) "back" IrPhiInputNil)
          (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrPhi
            1
            (compiler-ir-phi-input-cons (IrValueVar 0) "back" IrPhiInputNil)
            (AstTyI64))
          IrInstrNil)))
    IrBlockNil))

(define (compiler-backend-phi-group-cycle-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegisterPair "%r12" "%r13"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegisterPair "%r14" "%r15"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-phi-group-cycle-blocks) : CompilerIrBlockList
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    (compiler-ir-block-cons
      (compiler-ir-block
        "join"
        (compiler-ir-instr-cons
          (IrInstrPhi
            0
            (compiler-ir-phi-input-cons (IrValueVar 1) "back" IrPhiInputNil)
            ty)
          (compiler-ir-instr-cons
            (IrInstrPhi
              1
              (compiler-ir-phi-input-cons (IrValueVar 0) "back" IrPhiInputNil)
              ty)
            IrInstrNil)))
      IrBlockNil)))

(define (compiler-backend-branch-phi-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "body"
      (compiler-ir-instr-cons
        (IrInstrPhi
          0
          (compiler-ir-phi-input-cons
            (IrValueI64 1)
            "entry"
            (compiler-ir-phi-input-cons (IrValueVar 1) "body" IrPhiInputNil))
          (AstTyI64))
        IrInstrNil))
    (compiler-ir-block-cons (compiler-ir-block "exit" IrInstrNil) IrBlockNil)))

(define (compiler-backend-branch-phi-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r14"))
        CompilerRegAssignmentNil))))

(define (compiler-backend-branch-phi-edge-copy-ok?) : bool
  (begin
    (set!
      compiler-backend-current-phi-targets
      (compiler-backend-phi-target-labels-for-blocks
        (compiler-backend-branch-phi-blocks)))
    (match (compiler-backend-emit-compare-branch-with-phi-copies
      (compiler-backend-branch-phi-assignments)
      "phi_edge"
      (compiler-backend-branch-phi-blocks)
      "entry"
      (IrBinLt)
      (IrValueI64 1)
      (IrValueVar 2)
      (AstTyI64)
      "body"
      "exit"
      (CompilerBackendNoLabel)
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)
      4)
      [(OkCompilerBackend asm)
        (and
          (compiler-backend-string-contains? asm "    jge .Lphi_edge_exit\n")
          (not
            (compiler-backend-string-contains?
              asm
              "    jl .Lphi_edge_entry_branch_true\n"))
          (compiler-backend-string-contains?
            asm
            ".Lphi_edge_entry_branch_true:\n")
          (compiler-backend-string-contains? asm "    movl $1, %r12d\n")
          (not (compiler-backend-string-contains? asm "    movq %rax, %r12\n"))
          (not
            (compiler-backend-string-contains?
              asm
              ".Lphi_edge_entry_branch_false:\n"))
          (compiler-backend-string-contains? asm "    jmp .Lphi_edge_body\n"))]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-phi-immediate-stack-copy-ok?) : bool
  (match (compiler-backend-emit-phi-edge-copies
    CompilerRegAssignmentNil
    (compiler-backend-branch-phi-blocks)
    "body"
    "entry"
    (compiler-backend-program-index-build IrFunctionNil IrExternNil)
    4)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movq $1, -8(%rbp)\n")
        (not (compiler-backend-string-contains? asm "    movl $1, %eax\n"))
        (not
          (compiler-backend-string-contains? asm "    movq %rax, -8(%rbp)\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-phi-direct-scalar-copy-ok?) : bool
  (match (compiler-backend-emit-phi-edge-copies
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
        CompilerRegAssignmentNil))
    (compiler-backend-branch-phi-blocks)
    "body"
    "body"
    (compiler-backend-program-index-build IrFunctionNil IrExternNil)
    4)
    [(OkCompilerBackend reg-reg)
      (match (compiler-backend-emit-phi-edge-copies
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
          (compiler-reg-assignment-cons
            (CompilerRegAssignment 1 (CompilerRegSpill -16))
            CompilerRegAssignmentNil))
        (compiler-backend-branch-phi-blocks)
        "body"
        "body"
        (compiler-backend-program-index-build IrFunctionNil IrExternNil)
        4)
        [(OkCompilerBackend spill-reg)
          (match (compiler-backend-emit-phi-edge-copies
            (compiler-reg-assignment-cons
              (CompilerRegAssignment 0 (CompilerRegSpill -8))
              (compiler-reg-assignment-cons
                (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
                CompilerRegAssignmentNil))
            (compiler-backend-branch-phi-blocks)
            "body"
            "body"
            (compiler-backend-program-index-build IrFunctionNil IrExternNil)
            4)
            [(OkCompilerBackend reg-spill)
              (and
                (compiler-backend-string-contains?
                  reg-reg
                  "    movq %r13, %r12\n")
                (not
                  (compiler-backend-string-contains?
                    reg-reg
                    "    movq %r13, %rax\n"))
                (compiler-backend-string-contains?
                  spill-reg
                  "    movq -16(%rbp), %r12\n")
                (not
                  (compiler-backend-string-contains?
                    spill-reg
                    "    movq -16(%rbp), %rax\n"))
                (compiler-backend-string-contains?
                  reg-spill
                  "    movq %r13, -8(%rbp)\n")
                (not
                  (compiler-backend-string-contains?
                    reg-spill
                    "    movq %r13, %rax\n")))]
            [(ErrCompilerBackend _) false])]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-phi-return-entry-asm
  [blocks : CompilerIrBlockList]
  [entry-instrs : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : ResultCompilerBackend
  (let
    [use-counts : (Array i64)
      (compiler-backend-function-use-counts vars blocks)]
    (compiler-backend-emit-instrs
      (BackendTargetLinux)
      "_tl_test"
      "test"
      blocks
      "entry"
      (CompilerBackendNoLabel)
      entry-instrs
      assignments
      vars
      CompilerRegVarTypeNil
      (CompilerBackendGlobalTypeNil)
      (AstTyI64)
      (compiler-backend-runtime-helper-full-plan)
      IrFunctionNil
      IrExternNil
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)
      (compiler-source-spans-empty)
      (compiler-diagnostic-at-start "" "")
      use-counts
      (text-buf-empty))))

(define (compiler-backend-single-phi-return-entry-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueI64 7) (AstTyI64))
    (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil)))

(define (compiler-backend-single-phi-return-join-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrPhi
      0
      (compiler-ir-phi-input-cons (IrValueVar 1) "entry" IrPhiInputNil)
      (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrReturn (IrSomeValue (IrValueVar 0)))
      IrInstrNil)))

(define (compiler-backend-single-phi-return-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-backend-single-phi-return-entry-instrs))
    (compiler-ir-block-cons
      (compiler-ir-block
        "join"
        (compiler-backend-single-phi-return-join-instrs))
      IrBlockNil)))

(define (compiler-backend-single-phi-return-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r14"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-single-phi-return-shortcut-ok?) : bool
  (match (compiler-backend-phi-return-entry-asm
    (compiler-backend-single-phi-return-blocks)
    (compiler-backend-single-phi-return-entry-instrs)
    (compiler-backend-single-phi-return-assignments)
    2)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movl $7, %eax\n")
        (not (compiler-backend-string-contains? asm "    movl $7, %r14d\n"))
        (not (compiler-backend-string-contains? asm "    movq %r14, %r12\n"))
        (not
          (compiler-backend-string-contains? asm "    jmp .L_tl_test_join\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-multi-phi-return-entry-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 2 (IrValueI64 7) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 3 (IrValueI64 11) (AstTyI64))
      (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil))))

(define (compiler-backend-multi-phi-return-join-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrPhi
      0
      (compiler-ir-phi-input-cons (IrValueVar 3) "entry" IrPhiInputNil)
      (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrPhi
        1
        (compiler-ir-phi-input-cons (IrValueVar 2) "entry" IrPhiInputNil)
        (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrPhi
          4
          (compiler-ir-phi-input-cons (IrValueI64 99) "entry" IrPhiInputNil)
          (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 1)))
          IrInstrNil)))))

(define (compiler-backend-multi-phi-return-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block "entry" (compiler-backend-multi-phi-return-entry-instrs))
    (compiler-ir-block-cons
      (compiler-ir-block "join" (compiler-backend-multi-phi-return-join-instrs))
      IrBlockNil)))

(define (compiler-backend-multi-phi-return-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r14"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 3 (CompilerRegRegister "%r15"))
          (compiler-reg-assignment-cons
            (CompilerRegAssignment 4 (CompilerRegRegister "%rbx"))
            CompilerRegAssignmentNil))))))

(define (compiler-backend-multi-phi-return-shortcut-ok?) : bool
  (match (compiler-backend-phi-return-entry-asm
    (compiler-backend-multi-phi-return-blocks)
    (compiler-backend-multi-phi-return-entry-instrs)
    (compiler-backend-multi-phi-return-assignments)
    5)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movl $7, %r14d\n")
        (compiler-backend-string-contains? asm "    movq %r14, %rax\n")
        (not (compiler-backend-string-contains? asm "    movq %r14, %r13\n"))
        (not (compiler-backend-string-contains? asm "    movl $99, %ebx\n"))
        (not
          (compiler-backend-string-contains? asm "    jmp .L_tl_test_join\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-phi-return-work-join-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrPhi
      0
      (compiler-ir-phi-input-cons (IrValueVar 1) "entry" IrPhiInputNil)
      (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 2 (IrValueI64 99) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueVar 0)))
        IrInstrNil))))

(define (compiler-backend-phi-return-work-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-backend-single-phi-return-entry-instrs))
    (compiler-ir-block-cons
      (compiler-ir-block "join" (compiler-backend-phi-return-work-join-instrs))
      IrBlockNil)))

(define (compiler-backend-phi-return-work-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r14"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r15"))
        CompilerRegAssignmentNil))))

(define (compiler-backend-phi-return-rejects-work-ok?) : bool
  (match (compiler-backend-phi-return-entry-asm
    (compiler-backend-phi-return-work-blocks)
    (compiler-backend-single-phi-return-entry-instrs)
    (compiler-backend-phi-return-work-assignments)
    3)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movl $7, %r12d\n")
        (compiler-backend-string-contains? asm "    jmp .L_tl_test_join\n")
        (not (compiler-backend-string-contains? asm "    movq %r14, %rax\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-mov-phi-copy-entry-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 2 (IrValueI64 7) (AstTyI64))
    (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil)))

(define (compiler-backend-mov-phi-copy-join-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrPhi
      0
      (compiler-ir-phi-input-cons (IrValueVar 2) "entry" IrPhiInputNil)
      (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueVar 1)))
        IrInstrNil))))

(define (compiler-backend-mov-phi-copy-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block "entry" (compiler-backend-mov-phi-copy-entry-instrs))
    (compiler-ir-block-cons
      (compiler-ir-block "join" (compiler-backend-mov-phi-copy-join-instrs))
      IrBlockNil)))

(define (compiler-backend-mov-phi-copy-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r14"))
        CompilerRegAssignmentNil))))

(define (compiler-backend-mov-phi-copy-fusion-ok?) : bool
  (let
    [blocks : CompilerIrBlockList (compiler-backend-mov-phi-copy-blocks)]
    [use-counts : (Array i64) (compiler-backend-function-use-counts 3 blocks)]
    (match (compiler-backend-emit-instrs
      (BackendTargetLinux)
      "_tl_test"
      "test"
      blocks
      "entry"
      (CompilerBackendNoLabel)
      (compiler-backend-mov-phi-copy-entry-instrs)
      (compiler-backend-mov-phi-copy-assignments)
      3
      CompilerRegVarTypeNil
      (CompilerBackendGlobalTypeNil)
      (AstTyI64)
      (compiler-backend-runtime-helper-full-plan)
      IrFunctionNil
      IrExternNil
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)
      (compiler-source-spans-empty)
      (compiler-diagnostic-at-start "" "")
      use-counts
      (text-buf-empty))
      [(OkCompilerBackend asm)
        (and
          (compiler-backend-string-contains? asm "    movl $7, %r12d\n")
          (not (compiler-backend-string-contains? asm "    movl $7, %r14d\n"))
          (not (compiler-backend-string-contains? asm "    movq %r14, %r12\n"))
          (compiler-backend-string-contains? asm "    jmp .L_tl_test_join\n"))]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-phi-parallel-copy-ok?) : bool
  (match (compiler-backend-emit-phi-edge-copies
    (compiler-backend-phi-same-home-assignments)
    (compiler-backend-phi-same-home-blocks)
    "join"
    "entry"
    (compiler-backend-program-index-build IrFunctionNil IrExternNil)
    0)
    [(OkCompilerBackend same-home)
      (match (compiler-backend-emit-phi-edge-copies
        CompilerRegAssignmentNil
        (compiler-backend-phi-cycle-blocks)
        "join"
        "back"
        (compiler-backend-program-index-build IrFunctionNil IrExternNil)
        0)
        [(OkCompilerBackend cycle)
          (and
            (string-eq same-home "")
            (compiler-backend-string-contains?
              cycle
              "    movq -8(%rbp), %r11\n")
            (compiler-backend-string-contains?
              cycle
              "    movq -16(%rbp), %rax\n")
            (compiler-backend-string-contains?
              cycle
              "    movq %rax, -8(%rbp)\n")
            (compiler-backend-string-contains?
              cycle
              "    movq %r11, -16(%rbp)\n"))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-phi-group-cycle-copy-ok?) : bool
  (match (compiler-backend-emit-phi-edge-copies
    (compiler-backend-phi-group-cycle-assignments)
    (compiler-backend-phi-group-cycle-blocks)
    "join"
    "back"
    (compiler-backend-register-group-test-index)
    4)
    [(OkCompilerBackend cycle)
      (and
        (compiler-backend-string-contains? cycle "    movq %r12, %r10\n")
        (compiler-backend-string-contains? cycle "    movq %r13, %r11\n")
        (compiler-backend-string-contains? cycle "    movq %r14, %rax\n")
        (compiler-backend-string-contains? cycle "    movq %r15, %rdx\n")
        (compiler-backend-string-contains? cycle "    movq %rax, %r12\n")
        (compiler-backend-string-contains? cycle "    movq %rdx, %r13\n")
        (compiler-backend-string-contains? cycle "    movq %r10, %r14\n")
        (compiler-backend-string-contains? cycle "    movq %r11, %r15\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-reg-is? [r : ResultBackendReg] [name : String]) : bool
  (match r
    [(OkBackendReg reg) (string-eq reg name)]
    [(ErrBackendReg _) false]))

(define (compiler-backend-reg-err? [r : ResultBackendReg]) : bool
  (match r
    [(OkBackendReg _) false]
    [(ErrBackendReg _) true]))

;; The target model (#646/#647): per-target arg registers / shadow space /
;; entry symbol; the Linux path is byte-identical to the default emitter and the
;; Windows path emits ABI-shaped user-function assembly and runtime helpers
;; without Linux syscalls.
(define (compiler-backend-target-model-ok? [src : String]) : bool
  (and
    (compiler-backend-reg-is?
      (compiler-backend-target-arg-reg (BackendTargetLinux) 0)
      "%rdi")
    (compiler-backend-reg-is?
      (compiler-backend-target-arg-reg (BackendTargetWindows) 0)
      "%rcx")
    (compiler-backend-reg-is?
      (compiler-backend-target-arg-reg (BackendTargetWindows) 3)
      "%r9")
    (compiler-backend-reg-err?
      (compiler-backend-target-arg-reg (BackendTargetWindows) 4))
    (= (compiler-backend-outgoing-shadow-space (BackendTargetLinux)) 0)
    (= (compiler-backend-outgoing-shadow-space (BackendTargetWindows)) 32)
    (compiler-backend-string-contains?
      (compiler-backend-target-entry-text (BackendTargetLinux) true)
      "_tl_start")
    (compiler-backend-string-contains?
      (compiler-backend-target-entry-text (BackendTargetWindows) true)
      ".globl main")
    (compiler-backend-target-linux-no-entry-ok? src)
    (compiler-backend-target-linux-crt-entry-ok?)
    (compiler-backend-target-linux-matches-default? src)
    (compiler-backend-target-windows-abi-ok?)
    (compiler-backend-target-windows-callee-save-ok?)
    (compiler-backend-target-windows-stack-probe-ok?)
    (compiler-backend-target-windows-runtime-ok?)))

(define (compiler-backend-target-linux-matches-default? [src : String]) : bool
  (match (compiler-backend-emit-source-for-target src (BackendTargetLinux))
    [(OkCompilerBackend linux-asm)
      (match (compiler-backend-emit-source src)
        [(OkCompilerBackend default-asm) (string-eq linux-asm default-asm)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-linux-no-entry-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-with-spans-for-target-and-entry
        program
        spans
        (BackendTargetLinux)
        false)
        [(OkCompilerBackend asm)
          (and
            (compiler-backend-string-contains? asm ".text\n")
            (compiler-backend-string-contains? asm "main:\n")
            (not (compiler-backend-string-contains? asm ".globl _tl_start\n"))
            (not (compiler-backend-string-contains? asm "_tl_start:\n")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-target-linux-crt-entry-source) : String
  "(extern (arg-count) : i64 (:symbol \"tl_arg_count\"))
(define (seed) : i64 41)
(define value
  (seed))
(define (main) : i64
  (+ value (arg-count)))")

(define (compiler-backend-target-linux-crt-entry-ok?) : bool
  (match (lower-compiler-source
    (compiler-backend-target-linux-crt-entry-source))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode-and-crt
        program
        (BackendTargetLinux)
        (BackendModeScalar)
        spans
        true
        true)
        [(OkCompilerBackend asm)
          (and
            (compiler-backend-string-contains?
              (compiler-backend-target-entry-text-with-crt
                (BackendTargetLinux)
                true
                true)
              ".globl main")
            (compiler-backend-string-contains? asm "main:\n")
            (compiler-backend-string-contains?
              asm
              "    movq %rdi, .L_tl_argc(%rip)\n")
            (compiler-backend-string-contains?
              asm
              "    call _tl___global_init_")
            (not (compiler-backend-string-contains? asm ".globl _tl_start\n"))
            (not (compiler-backend-string-contains? asm "_tl_start:\n")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-target-windows-stack-probe-ok?) : bool
  (let
    [win : String (compiler-backend-emit-stack-sub (BackendTargetWindows) 4800)]
    [linux : String (compiler-backend-emit-stack-sub (BackendTargetLinux) 4800)]
    (and
      (compiler-backend-string-contains? win "    movl $4800, %eax\n")
      (compiler-backend-string-contains? win "    callq __chkstk\n")
      (compiler-backend-string-contains? win "    subq %rax, %rsp\n")
      (not (compiler-backend-string-contains? win "    subq $4800, %rsp\n"))
      (compiler-backend-string-contains? linux "    subq $4800, %rsp\n")
      (not (compiler-backend-string-contains? linux "__chkstk")))))

(define (compiler-backend-target-windows-abi-source) : String
  "(extern (ext [arg0 : i64] [arg1 : i64] [arg2 : i64] [arg3 : i64] [arg4 : i64]) : i64)
(define (call5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : i64
  (ext a b c d e))
(define (main) : i64
  (call5 1 2 3 4 5))")

(define (compiler-backend-target-windows-abi-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-target-windows-abi-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".globl main\n")
          (not (compiler-backend-string-contains? asm "\n_start:\n"))
          (not (compiler-backend-string-contains? asm "syscall\n"))
          (compiler-backend-string-contains? asm "    movq %rcx, -8(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq %rdx, -16(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq %r8, -24(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq %r9, -32(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq 48(%rbp), %rax\n"))
        (compiler-backend-string-contains? asm "    movq %r11, 32(%rsp)\n")
        (compiler-backend-string-contains? asm "    call ext\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-windows-callee-save-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-callee-save-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm ".seh_pushreg %r12"))
        ;; Runtime shims may use callee-saved registers internally; this check
        ;; covers user-function allocation, where `%r12` must not be selected.
        (not (compiler-backend-string-contains? asm "    movq %r12, -")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-windows-runtime-ok?) : bool
  (match (compiler-backend-emit-program-for-target
    (compiler-backend-runtime-helper-program)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (let
        [kernel-io
          : bool
          ;; tl_alloc obtains memory via VirtualAlloc and, on exhaustion,
          ;; tail-jumps to the `tl_oom_abort` runtime-prelude handler (#2221) —
          ;; it no longer inlines a kernel32 WriteFile for the OOM message.
          (backend-and4
            (compiler-backend-string-contains? asm ".globl tl_alloc\n")
            (compiler-backend-string-contains? asm "    call VirtualAlloc\n")
            (compiler-backend-string-contains?
              asm
              ".L_tl_alloc_abort:\n    sub $32, %rsp\n    call tl_oom_abort\n")
            (not (compiler-backend-string-contains? asm "    call _write\n")))]
        [no-process-runtime : bool
          (backend-and4
            (not (compiler-backend-string-contains? asm "    call _lseeki64\n"))
            (not (compiler-backend-string-contains? asm "    call _read\n"))
            (not (compiler-backend-string-contains? asm "tl_process_output:\n"))
            (not (compiler-backend-string-contains? asm "tmpfile:\n")))]
        [string-runtime : bool
          (backend-and8
            (compiler-backend-string-contains? asm "tl_substring:\n")
            (compiler-backend-string-contains? asm "tl_string_concat:\n")
            (not (compiler-backend-string-contains? asm "tl_string_eq:\n"))
            (not (compiler-backend-string-contains? asm "tl_string_to_int:\n"))
            (compiler-backend-string-contains? asm "tl_int_to_string:\n")
            (not
              (compiler-backend-string-contains? asm "tl_random_system_seed:\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_random_system_seed\n"))
            (compiler-backend-no-stdlib-forwarding-labels? asm))]
        [entry-shape : bool
          (backend-and4
            (compiler-backend-string-contains?
              asm
              "    movq %rcx, .L_tl_argc(%rip)\n")
            (compiler-backend-string-contains? asm "    .extern VirtualAlloc\n")
            (not (compiler-backend-string-contains? asm "syscall\n"))
            (not (compiler-backend-string-contains? asm ".globl _start\n")))]
        [private-file-handles : bool
          (not
            (compiler-backend-string-contains? asm ".L_tl_file_handle_next:\n"))]
        [driver-runtime : bool (compiler-backend-windows-driver-runtime-ok?)]
        [no-advapi-random : bool
          (not (compiler-backend-string-contains? asm "SystemFunction036"))]
        (backend-and8
          kernel-io
          true
          no-process-runtime
          string-runtime
          entry-shape
          private-file-handles
          driver-runtime
          no-advapi-random))]
    [(ErrCompilerBackend message) false]))

(define (compiler-backend-windows-runtime-guard-source) : String
  "(extern (tl_alloc [arg0 : u64]) : u64)
(extern (tl_region_reset [arg0 : u64]) : unit)
(define (main) : u64
  (begin
    (tl_region_reset (cast 0 : u64))
    (tl_alloc (cast 0 : u64))))")

(define (compiler-backend-windows-runtime-guard-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-windows-runtime-guard-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "tl_alloc:\n")
          (compiler-backend-string-contains?
            asm
            "    testq %rcx, %rcx\n    jnz .L_tl_alloc_win_size_ready\n")
          (not
            (compiler-backend-string-contains?
              asm
              "    testq %rcx, %rcx\n    jg .L_tl_alloc_win_size_ready\n"))
          (compiler-backend-string-contains?
            asm
            "    jc .L_tl_alloc_enter_abort\n")
          (and
            (compiler-backend-string-contains?
              asm
              ".L_tl_region_reset_win_invalid:\n")
            (compiler-backend-string-contains?
              asm
              "    sub $32, %rsp\n    call tl_region_abort\n"))
          ;; The out-of-memory abort moved to the `tl_oom_abort` runtime-prelude
          ;; handler (#2221): the allocator's abort path now tail-jumps to it
          ;; instead of inlining the kernel32 GetStdHandle/WriteFile/ExitProcess
          ;; write (the former `.L_tl_win_write_abort` helper is gone).
          (backend-and4
            (compiler-backend-string-contains?
              asm
              ".L_tl_alloc_abort:\n    sub $32, %rsp\n    call tl_oom_abort\n")
            (not
              (compiler-backend-string-contains? asm ".L_tl_win_write_abort"))
            (not (compiler-backend-string-contains? asm "    call WriteFile\n"))
            (not
              (compiler-backend-string-contains? asm "    call GetStdHandle\n")))
          (compiler-backend-string-contains?
            asm
            "    push %r14\n    movq %rcx, %r12\n")
          (not
            (compiler-backend-string-contains?
              asm
              "    push %r14\n    sub $8, %rsp\n    movq %rcx, %r12\n")))
        (not (compiler-backend-string-contains? asm "syscall\n"))
        (not (compiler-backend-string-contains? asm "    .extern _write\n"))
        (not (compiler-backend-string-contains? asm "    .extern exit\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-syscall-source) : String
  "(define (ptr-i64 [p : (Ptr u8)]) : i64
  (cast (unsafe (ptr->int p)) : i64))

(define (main) : i64
  (let
    [message : String \"syscall-ok\\n\"]
    [addr : i64 (ptr-i64 (unsafe (string-data message)))]
    [wrote : i64 (unsafe (syscall 1 1 addr (string-length message)))]
    [bad-read : i64 (unsafe (syscall 0 -1 addr 1))]
    (if (if (= wrote (string-length message)) (= bad-read -9) false)
      (begin
        (unsafe (syscall 231 42))
        1)
      2)))")

(define (compiler-backend-syscall-source-linux-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-syscall-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "    syscall\n")
          (compiler-backend-string-contains? asm ", %rax\n")
          (compiler-backend-string-contains? asm ", %rdi\n")
          (compiler-backend-string-contains? asm ", %rsi\n")
          (compiler-backend-string-contains? asm ", %rdx\n")
          (compiler-backend-string-contains? asm "    movq $231,")
          (compiler-backend-string-contains? asm "    movq $42,")
          true)
        (not (compiler-backend-string-contains? asm "    pushq %rax\n"))
        (not (compiler-backend-string-contains? asm "    popq "))
        (not (compiler-backend-string-contains? asm ".extern syscall\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-syscall-source-windows-guard-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-syscall-source)
    (BackendTargetWindows))
    [(ErrCompilerBackend diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "backend: syscall is only supported on the linux-x86_64 target")]
    [(OkCompilerBackend _) false]))

(define (compiler-backend-syscall-source-ok?) : bool
  (and
    (compiler-backend-syscall-source-linux-ok?)
    (compiler-backend-syscall-source-windows-guard-ok?)))

(define (compiler-backend-deterministic-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend first)
      (match (compiler-backend-emit-source src)
        [(OkCompilerBackend second) (string-eq first second)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-error-ok? [src : String] [want : String]) : bool
  (match (compiler-backend-emit-source src)
    [(ErrCompilerBackend message)
      (string-eq (compiler-diagnostic-message message) want)]
    [(OkCompilerBackend _) false]))

(define (compiler-backend-source-contains? [src : String] [needle : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm) (compiler-backend-string-contains? asm needle)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-source-not-contains? [src : String] [needle : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm)
      (not (compiler-backend-string-contains? asm needle))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-test-span [line : i64] [col : i64]) : AstSourceSpan
  (AstSourceSpan line col line col))

(define (compiler-backend-instr-diagnostic-case-ok?
  [instr : CompilerIrInstr]
  [want-message : String]
  [want-line : i64]
  [want-col : i64]) : bool
  (let
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert
          (compiler-source-spans-empty)
          "main"
          (compiler-backend-test-span 10 2))
        "main"
        instr
        (compiler-backend-test-span want-line want-col))]
    [program : CompilerIrProgram
      (IrProgram
        IrGlobalNil
        (compiler-ir-function-cons
          (IrFunction
            "main"
            IrParamNil
            (AstTyI64)
            4
            (compiler-ir-block-cons
              (compiler-ir-block
                "entry"
                (compiler-ir-instr-cons instr IrInstrNil))
              IrBlockNil))
          IrFunctionNil)
        IrExternNil)]
    (match (compiler-backend-emit-program-linux-with-spans program spans)
      [(ErrCompilerBackend diag)
        (and
          (string-eq (compiler-diagnostic-message diag) want-message)
          (= (compiler-diagnostic-line diag) want-line)
          (= (compiler-diagnostic-col diag) want-col))]
      [(OkCompilerBackend _) false])))

(define (compiler-backend-instr-diagnostics-ok?) : bool
  (and
    (compiler-backend-instr-diagnostic-case-ok?
      (IrInstrMov 0 (IrValueF64 "1.0") (AstTyI64))
      "backend: f64 values are not supported yet"
      21
      7)
    (compiler-backend-instr-diagnostic-case-ok?
      (IrInstrBinOp
        1
        (IrBinMod)
        (IrValueF64 "1.0")
        (IrValueF64 "2.0")
        (AstTyF64))
      "backend: unsupported f64 binary op"
      34
      9)
    ;; #1044: an f64 unary op other than negation is rejected (mirrors the
    ;; f64-binary-op reject; only IrUnNeg has an f64 lowering).
    (compiler-backend-instr-diagnostic-case-ok?
      (IrInstrUnOp 2 (IrUnNot) (IrValueF64 "1.0") (AstTyF64))
      "backend: unsupported f64 unary op"
      40
      11)
    (compiler-backend-instr-diagnostic-case-ok?
      (IrInstrVectorBinOp
        3
        (IrBinMod)
        (IrValueVar 0)
        (IrValueVar 1)
        8
        (AstTyI64))
      "backend: unsupported AVX-512 vector binary op"
      44
      13)))

(define (compiler-backend-avx2-map-source [elem : String]) : String
  (str-cat
    "(define (fill [a : (Array "
    elem
    ")] [b : (Array "
    elem
    ")] [out : (Array "
    elem
    ")] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))"))

(define (compiler-backend-uniform-map-source [elem : String]) : String
  (str-cat
    "(define (fill [a : (Array "
    elem
    ")] [b : (Array "
    elem
    ")] [out : (Array "
    elem
    ")] [n : i64] [r : "
    elem
    "]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))"))

(define (compiler-backend-uniform-zip-source) : String
  "(define (fill [a : (Array i64)] [b : (Array i64)] [c : (Array i64)] [out : (Array i64)] [n : i64] [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (* (array-ref a i) (array-ref b i)) (array-ref c i)) r))))")

(define (compiler-backend-avx2-map-asm-contains?
  [elem : String]
  [move : String]
  [op : String]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-avx2-map-source elem)
    (CompilerLowerAvx2))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx2)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and4
              (compiler-backend-string-contains? asm "    vzeroupper\n")
              (compiler-backend-string-contains? asm move)
              (compiler-backend-string-contains? asm op)
              (compiler-backend-string-contains? asm "%ymm"))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx2-vector-map-ok?) : bool
  (and
    (compiler-backend-avx2-map-asm-contains? "i64" "    vmovdqu " "    vpaddq ")
    (compiler-backend-avx2-map-asm-contains? "i32" "    vmovdqu " "    vpaddd ")
    (compiler-backend-avx2-map-asm-contains? "i16" "    vmovdqu " "    vpaddw ")
    (compiler-backend-avx2-map-asm-contains? "u16" "    vmovdqu " "    vpaddw ")
    (compiler-backend-avx2-map-asm-contains? "f64" "    vmovupd " "    vaddpd ")
    (compiler-backend-avx2-map-asm-contains? "f32" "    vmovups " "    vaddps ")
    (compiler-backend-avx2-map-asm-contains? "i8" "    vmovdqu " "    vpaddb ")
    (compiler-backend-avx2-map-asm-contains? "u8" "    vmovdqu " "    vpaddb ")))

(define (compiler-backend-avx2-uniform-map-asm-contains?
  [elem : String]
  [move : String]
  [op : String]
  [broadcast : String]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-uniform-map-source elem)
    (CompilerLowerAvx2))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx2)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vzeroupper\n")
              (compiler-backend-string-contains? asm move)
              (compiler-backend-string-contains? asm op)
              (compiler-backend-string-contains? asm broadcast)
              (compiler-backend-string-contains? asm "%ymm")
              (not
                (compiler-backend-string-contains?
                  asm
                  "vector/mask IR emission is not implemented"))
              true
              true)
            true)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx2-uniform-zip-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-uniform-zip-source)
    (CompilerLowerAvx2))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx2)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vpbroadcastq %xmm0, ")
              (compiler-backend-string-contains? asm "    vpmuludq ")
              (compiler-backend-string-contains? asm "    vpsllq $32, ")
              (compiler-backend-string-contains? asm "    vpaddq ")
              (compiler-backend-string-contains? asm "    vmovdqu ")
              (compiler-backend-string-contains? asm "%ymm")
              (not
                (compiler-backend-string-contains?
                  asm
                  "vector/mask IR emission is not implemented"))
              true)
            true)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx2-uniform-vector-map-ok?) : bool
  (and
    (compiler-backend-avx2-uniform-map-asm-contains?
      "i64"
      "    vmovdqu "
      "    vpaddq "
      "    vpbroadcastq %xmm0, ")
    (compiler-backend-avx2-uniform-map-asm-contains?
      "i32"
      "    vmovdqu "
      "    vpaddd "
      "    vpbroadcastd %xmm0, ")
    (compiler-backend-avx2-uniform-map-asm-contains?
      "i16"
      "    vmovdqu "
      "    vpaddw "
      "    vpbroadcastw %xmm0, ")
    (compiler-backend-avx2-uniform-map-asm-contains?
      "u16"
      "    vmovdqu "
      "    vpaddw "
      "    vpbroadcastw %xmm0, ")
    (compiler-backend-avx2-uniform-map-asm-contains?
      "f64"
      "    vmovupd "
      "    vaddpd "
      "    vbroadcastsd %xmm0, ")
    (compiler-backend-avx2-uniform-map-asm-contains?
      "f32"
      "    vmovups "
      "    vaddps "
      "    vbroadcastss %xmm0, ")
    (compiler-backend-avx2-uniform-map-asm-contains?
      "i8"
      "    vmovdqu "
      "    vpaddb "
      "    vpbroadcastb %xmm0, ")
    (compiler-backend-avx2-uniform-map-asm-contains?
      "u8"
      "    vmovdqu "
      "    vpaddb "
      "    vpbroadcastb %xmm0, ")
    (compiler-backend-avx2-uniform-zip-ok?)))

(define (compiler-backend-avx512-masked-if-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (array-set! out i 0)
      (array-set! out i (+ (array-ref xs i) 1)))))")

(define (compiler-backend-avx512-masked-if-offset-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs (+ i 1)) 0)
      (array-set! out (+ i 1) 0)
      (array-set! out (+ i 1) (+ (array-ref xs (+ i 1)) 1)))))")

(define (compiler-backend-avx512-masked-if-index-value-source) : String
  "(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 6)
      (array-set! out i i)
      (array-set! out i (+ i 1)))))")

(define (compiler-backend-avx512-masked-if-index-mod-source) : String
  "(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (= (% i 2) 0)
      (array-set! out i (+ i 10))
      (array-set! out i (+ i 100)))))")

(define (compiler-backend-avx512-masked-if-value-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i
      (if (< (array-ref xs i) 0)
        0
        (+ (array-ref xs i) 1)))))")

(define (compiler-backend-avx512-select-alias-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%vec6"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%k1"))
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%vec6"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 3 (CompilerRegRegister "%vec7"))
          CompilerRegAssignmentNil)))))

(define (compiler-backend-avx512-select-true-alias-ok?) : bool
  (match (compiler-backend-emit-avx512-select
    (compiler-backend-avx512-select-alias-assignments)
    0
    (IrValueVar 1)
    (IrValueVar 2)
    (IrValueVar 3)
    8
    (AstTyI64)
    (compiler-diagnostic-at-start "" ""))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    vmovdqu64 %zmm6, %zmm15\n")
        (compiler-backend-string-contains? asm "    vmovdqu64 %zmm7, %zmm6\n")
        (compiler-backend-string-contains?
          asm
          "    vmovdqu64 %zmm15, %zmm6{%k1}\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-avx512-map-asm-contains?
  [elem : String]
  [move : String]
  [op : String]
  [mask-move : String]
  [mask-shift : String]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-avx2-map-source elem)
    (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm move)
              (compiler-backend-string-contains? asm op)
              (compiler-backend-string-contains? asm "%zmm")
              (compiler-backend-string-contains? asm "%k")
              (compiler-backend-string-contains? asm "tail_mask_")
              (compiler-backend-string-contains? asm "}{z}")
              (compiler-backend-string-contains? asm mask-move)
              (compiler-backend-string-contains? asm mask-shift))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-masked-if-source-ok? [src : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vpcmpq $1,")
              (compiler-backend-string-contains? asm "    kandw ")
              (compiler-backend-string-contains? asm "    knotw ")
              (compiler-backend-string-contains? asm "    vpbroadcastq ")
              (compiler-backend-string-contains? asm "}{z}")
              (compiler-backend-string-contains? asm "tail_mask_")
              (compiler-backend-string-contains? asm "%k")
              (compiler-backend-string-contains? asm "    vmovdqu64 "))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-masked-if-index-value-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-avx512-masked-if-index-value-source)
    (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vpcmpq $1,")
              (compiler-backend-string-contains? asm "    kandw ")
              (compiler-backend-string-contains? asm "    knotw ")
              (compiler-backend-string-contains? asm "    vpbroadcastq ")
              (compiler-backend-string-contains? asm "tail_mask_")
              (compiler-backend-string-contains? asm "lane_id_")
              (compiler-backend-string-contains? asm "    vpaddq ")
              (compiler-backend-string-contains? asm "    vmovdqu64 "))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-masked-if-index-mod-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-avx512-masked-if-index-mod-source)
    (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vpcmpq $0,")
              (compiler-backend-string-contains? asm "    kandw ")
              (compiler-backend-string-contains? asm "    knotw ")
              (compiler-backend-string-contains? asm "    vpbroadcastq ")
              (compiler-backend-string-contains? asm "tail_mask_")
              (compiler-backend-string-contains? asm "lane_id_")
              (compiler-backend-string-contains? asm "    vpandq ")
              (compiler-backend-string-contains? asm "    vmovdqu64 "))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-masked-if-value-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-avx512-masked-if-value-source)
    (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vpcmpq $1,")
              (compiler-backend-string-contains? asm "    kandw ")
              (compiler-backend-string-contains? asm "    knotw ")
              (compiler-backend-string-contains? asm "    vpbroadcastq ")
              (compiler-backend-string-contains? asm "    vmovdqu64 %zmm")
              (compiler-backend-string-contains? asm "{%k")
              (compiler-backend-string-contains? asm "tail_mask_")
              (compiler-backend-string-contains? asm "%k"))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-masked-if-ok?) : bool
  (and
    (compiler-backend-avx512-masked-if-source-ok?
      (compiler-backend-avx512-masked-if-source))
    (compiler-backend-avx512-masked-if-source-ok?
      (compiler-backend-avx512-masked-if-offset-source))
    (compiler-backend-avx512-masked-if-index-value-ok?)
    (compiler-backend-avx512-masked-if-index-mod-ok?)
    (compiler-backend-avx512-masked-if-value-ok?)
    (compiler-backend-avx512-select-true-alias-ok?)))

(define (compiler-backend-avx512-vector-map-ok?) : bool
  (and
    (compiler-backend-avx512-map-asm-contains?
      "i64"
      "    vmovdqu64 "
      "    vpaddq "
      "kmovw"
      "shll %cl, %eax")
    (compiler-backend-avx512-map-asm-contains?
      "i32"
      "    vmovdqu32 "
      "    vpaddd "
      "kmovw"
      "shll %cl, %eax")
    (compiler-backend-avx512-map-asm-contains?
      "i16"
      "    vmovdqu16 "
      "    vpaddw "
      "kmovd"
      "shll %cl, %eax")
    (compiler-backend-avx512-map-asm-contains?
      "u16"
      "    vmovdqu16 "
      "    vpaddw "
      "kmovd"
      "shll %cl, %eax")
    (compiler-backend-avx512-map-asm-contains?
      "f64"
      "    vmovupd "
      "    vaddpd "
      "kmovw"
      "shll %cl, %eax")
    (compiler-backend-avx512-map-asm-contains?
      "f32"
      "    vmovups "
      "    vaddps "
      "kmovw"
      "shll %cl, %eax")
    (compiler-backend-avx512-map-asm-contains?
      "i8"
      "    vmovdqu8 "
      "    vpaddb "
      "kmovq"
      "shlq %cl, %rax")
    (compiler-backend-avx512-map-asm-contains?
      "u8"
      "    vmovdqu8 "
      "    vpaddb "
      "kmovq"
      "shlq %cl, %rax")))

(define (compiler-backend-avx512-uniform-map-asm-contains?
  [elem : String]
  [move : String]
  [op : String]
  [broadcast : String]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-uniform-map-source elem)
    (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm move)
              (compiler-backend-string-contains? asm op)
              (compiler-backend-string-contains? asm broadcast)
              (compiler-backend-string-contains? asm "%zmm")
              (compiler-backend-string-contains? asm "%k")
              (compiler-backend-string-contains? asm "tail_mask_")
              (compiler-backend-string-contains? asm "}{z}")
              (not
                (compiler-backend-string-contains?
                  asm
                  "vector/mask IR emission is not implemented")))
            true)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-uniform-zip-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-backend-uniform-zip-source)
    (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vpbroadcastq %rax, ")
              (compiler-backend-string-contains? asm "    vpmullq ")
              (compiler-backend-string-contains? asm "    vpaddq ")
              (compiler-backend-string-contains? asm "    vmovdqu64 ")
              (compiler-backend-string-contains? asm "%zmm")
              (compiler-backend-string-contains? asm "%k")
              (not
                (compiler-backend-string-contains?
                  asm
                  "vector/mask IR emission is not implemented"))
              true)
            true)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-uniform-vector-map-ok?) : bool
  (and
    (compiler-backend-avx512-uniform-map-asm-contains?
      "i64"
      "    vmovdqu64 "
      "    vpaddq "
      "    vpbroadcastq %rax, ")
    (compiler-backend-avx512-uniform-map-asm-contains?
      "i32"
      "    vmovdqu32 "
      "    vpaddd "
      "    vpbroadcastd %eax, ")
    (compiler-backend-avx512-uniform-map-asm-contains?
      "i16"
      "    vmovdqu16 "
      "    vpaddw "
      "    vpbroadcastw %xmm0, ")
    (compiler-backend-avx512-uniform-map-asm-contains?
      "u16"
      "    vmovdqu16 "
      "    vpaddw "
      "    vpbroadcastw %xmm0, ")
    (compiler-backend-avx512-uniform-map-asm-contains?
      "f64"
      "    vmovupd "
      "    vaddpd "
      "    vbroadcastsd %xmm0, ")
    (compiler-backend-avx512-uniform-map-asm-contains?
      "f32"
      "    vmovups "
      "    vaddps "
      "    vbroadcastss %xmm0, ")
    (compiler-backend-avx512-uniform-map-asm-contains?
      "i8"
      "    vmovdqu8 "
      "    vpaddb "
      "    vpbroadcastb %xmm0, ")
    (compiler-backend-avx512-uniform-map-asm-contains?
      "u8"
      "    vmovdqu8 "
      "    vpaddb "
      "    vpbroadcastb %xmm0, ")
    (compiler-backend-avx512-uniform-zip-ok?)))

(define (compiler-backend-avx2-reduce-asm-contains?
  [src : String]
  [op : String]
  [extract : String]
  [horizontal : String]
  [store : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx2))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx2)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm "    vzeroupper\n")
              (compiler-backend-string-contains? asm extract)
              (compiler-backend-string-contains? asm horizontal)
              (compiler-backend-string-contains? asm op)
              (compiler-backend-string-contains? asm store)
              (compiler-backend-string-contains? asm "%ymm")
              (compiler-backend-string-contains? asm "spmd_reduce_avx2")
              (compiler-backend-string-contains? asm "spmd_reduce_tail"))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx2-vector-reduce-ok?) : bool
  (and
    (compiler-backend-avx2-reduce-asm-contains?
      "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
      "    vpaddq "
      "    vextracti128 $1, "
      "    vpsrldq $8, "
      "    vmovq %xmm0, %rax\n")
    (compiler-backend-avx2-reduce-asm-contains?
      "(define (f [xs : (Array i32)] [n : i64]) : i32 (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))"
      "    vpaddd "
      "    vextracti128 $1, "
      "    vpsrldq $8, "
      "    vmovd %xmm0, %eax\n")
    (compiler-backend-avx2-reduce-asm-contains?
      "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
      "    vpminsd "
      "    vextracti128 $1, "
      "    vpsrldq $8, "
      "    vmovd %xmm0, %eax\n")
    (compiler-backend-avx2-reduce-asm-contains?
      "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
      "    vpmaxsd "
      "    vextracti128 $1, "
      "    vpsrldq $8, "
      "    vmovd %xmm0, %eax\n")
    (compiler-backend-avx2-reduce-asm-contains?
      "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
      "    vaddpd "
      "    vextractf128 $1, "
      "    vaddsd "
      "    movsd %xmm0, ")))

(define (compiler-backend-avx512-reduce-asm-contains?
  [src : String]
  [op : String]
  [extract : String]
  [horizontal : String]
  [store : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx512))
    [(OkCompilerLower program spans)
      (match (compiler-backend-emit-program-target-with-mode
        program
        (BackendTargetLinux)
        (BackendModeAvx512)
        spans
        true)
        [(OkCompilerBackend asm)
          (and
            (backend-and8
              (compiler-backend-string-contains? asm extract)
              (compiler-backend-string-contains? asm horizontal)
              (compiler-backend-string-contains? asm op)
              (compiler-backend-string-contains? asm store)
              (compiler-backend-string-contains? asm "%zmm")
              (compiler-backend-string-contains? asm "%ymm")
              (compiler-backend-string-contains? asm "spmd_reduce_avx2")
              true)
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-vector-reduce-i64-minmax-ok?) : bool
  (and
    (compiler-backend-avx512-reduce-asm-contains?
      "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
      "    vpminsq "
      "    vextracti64x4 $1, "
      "    vpsrldq $8, "
      "    vmovq %xmm0, %rax\n")
    (compiler-backend-avx512-reduce-asm-contains?
      "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
      "    vpmaxsq "
      "    vextracti64x4 $1, "
      "    vpsrldq $8, "
      "    vmovq %xmm0, %rax\n")))

(define (compiler-backend-avx512-vector-reduce-ok?) : bool
  (and
    (compiler-backend-avx512-reduce-asm-contains?
      "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
      "    vpaddq "
      "    vextracti64x4 $1, "
      "    vpsrldq $8, "
      "    vmovq %xmm0, %rax\n")
    (compiler-backend-avx512-reduce-asm-contains?
      "(define (f [xs : (Array i32)] [n : i64]) : i32 (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))"
      "    vpaddd "
      "    vextracti64x4 $1, "
      "    vpsrldq $8, "
      "    vmovd %xmm0, %eax\n")
    (compiler-backend-avx512-reduce-asm-contains?
      "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
      "    vpminsd "
      "    vextracti64x4 $1, "
      "    vpsrldq $8, "
      "    vmovd %xmm0, %eax\n")
    (compiler-backend-avx512-reduce-asm-contains?
      "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
      "    vpmaxsd "
      "    vextracti64x4 $1, "
      "    vpsrldq $8, "
      "    vmovd %xmm0, %eax\n")
    (compiler-backend-avx512-reduce-asm-contains?
      "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
      "    vaddpd "
      "    vextractf64x4 $1, "
      "    vaddsd "
      "    movsd %xmm0, ")
    (compiler-backend-avx512-vector-reduce-i64-minmax-ok?)))

(define (compiler-backend-vector-home-program [func : CompilerIrFunction]) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons func IrFunctionNil)
    IrExternNil))

(define (compiler-backend-vector-call-lifetime-function) : CompilerIrFunction
  (IrFunction
    "vector_call_lifetime"
    IrParamNil
    (AstTyUnit)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrVectorLoad 0 (IrValueI64 0) (IrValueI64 0) 4 (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrCall 1 "side_effect" (IrCallArgsNil) (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrVectorBinOp
                2
                (IrBinAdd)
                (IrValueVar 0)
                (IrValueVar 0)
                4
                (AstTyI64))
              (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil)))))
      IrBlockNil)))

(define (compiler-backend-avx2-vector-homes-ok?) : bool
  (match (compiler-backend-emit-program-target-with-mode
    (compiler-backend-vector-home-program (compiler-reg-vector-home-function))
    (BackendTargetLinux)
    (BackendModeAvx2)
    (compiler-source-spans-empty)
    true)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    vmovdqu ")
        (compiler-backend-string-contains?
          asm
          "    vpaddq %ymm7, %ymm6, %ymm7\n")
        (compiler-backend-string-contains?
          asm
          "    vpaddq %ymm7, %ymm6, %ymm6\n")
        (not
          (compiler-backend-string-contains? asm "register home unavailable")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-avx512-mask-homes-ok?) : bool
  (match (compiler-backend-emit-program-target-with-mode
    (compiler-backend-vector-home-program (compiler-reg-mask-home-function))
    (BackendTargetLinux)
    (BackendModeAvx512)
    (compiler-source-spans-empty)
    true)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    kandw %k2, %k1, %k1\n")
        (compiler-backend-string-contains? asm "    knotw %k1, %k1\n")
        (not
          (compiler-backend-string-contains? asm "register home unavailable")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-avx512-mask-binop-same-dst-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%k1"))
    CompilerRegAssignmentNil))

(define (compiler-backend-avx512-mask-binop-copy-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment 0 (CompilerRegRegister "%k1"))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 1 (CompilerRegRegister "%k2"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-avx512-mask-binop-emits?
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrMaskBinOp]
  [want : String]) : bool
  (match (compiler-backend-emit-avx512-mask-binop
    assignments
    dst
    op
    (IrValueVar 0)
    (IrValueVar 0)
    8
    (compiler-diagnostic-at-start "" ""))
    [(OkCompilerBackend asm) (string-eq asm want)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-avx512-mask-binop-same-registers-ok?) : bool
  (and
    (compiler-backend-avx512-mask-binop-emits?
      (compiler-backend-avx512-mask-binop-same-dst-assignments)
      0
      (IrMaskAnd)
      "")
    (compiler-backend-avx512-mask-binop-emits?
      (compiler-backend-avx512-mask-binop-same-dst-assignments)
      0
      (IrMaskOr)
      "")
    (compiler-backend-avx512-mask-binop-emits?
      (compiler-backend-avx512-mask-binop-copy-assignments)
      1
      (IrMaskAnd)
      "    kmovw %k1, %k2\n")
    (compiler-backend-avx512-mask-binop-emits?
      (compiler-backend-avx512-mask-binop-copy-assignments)
      1
      (IrMaskOr)
      "    kmovw %k1, %k2\n")))

(define (compiler-backend-vector-call-lifetime-rejects-ok?) : bool
  (match (compiler-backend-emit-program-target-with-mode
    (compiler-backend-vector-home-program
      (compiler-backend-vector-call-lifetime-function))
    (BackendTargetLinux)
    (BackendModeAvx2)
    (compiler-source-spans-empty)
    true)
    [(ErrCompilerBackend diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "backend: vector register home unavailable for load dst; unsupported spill, call, or ABI lifetime")]
    [(OkCompilerBackend _) false]))

(define (compiler-backend-simd-vector-ok?) : bool
  (and
    (compiler-backend-avx2-vector-map-ok?)
    (compiler-backend-avx512-vector-map-ok?)
    (compiler-backend-avx2-uniform-vector-map-ok?)
    (compiler-backend-avx512-uniform-vector-map-ok?)
    (compiler-backend-avx512-masked-if-ok?)
    (compiler-backend-avx2-vector-reduce-ok?)
    (compiler-backend-avx512-vector-reduce-ok?)
    (compiler-backend-avx2-vector-homes-ok?)
    (compiler-backend-avx512-mask-homes-ok?)
    (compiler-backend-avx512-mask-binop-same-registers-ok?)
    (compiler-backend-vector-call-lifetime-rejects-ok?)))

(define (compiler-backend-optimizer-rewrite-diagnostic-ok?) : bool
  (let
    [phi : CompilerIrInstr
      (IrInstrPhi
        0
        (compiler-ir-phi-input-cons (IrValueF64 "1.0") "entry" IrPhiInputNil)
        (AstTyI64))]
    [program : CompilerIrProgram
      (IrProgram
        IrGlobalNil
        (compiler-ir-function-cons
          (IrFunction
            "main"
            IrParamNil
            (AstTyI64)
            4
            (compiler-ir-block-cons
              (compiler-ir-block
                "entry"
                (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil))
              (compiler-ir-block-cons
                (compiler-ir-block
                  "join"
                  (compiler-ir-instr-cons
                    phi
                    (compiler-ir-instr-cons
                      (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                      IrInstrNil)))
                IrBlockNil)))
          IrFunctionNil)
        IrExternNil)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert
          (compiler-source-spans-empty)
          "main"
          (compiler-backend-test-span 10 2))
        "main"
        phi
        (compiler-backend-test-span 55 13))]
    (match (optimize-program-with-spans program spans)
      [(CompilerOptimizedProgram optimized optimized-spans)
        (match (compiler-backend-emit-program-linux-with-spans
          optimized
          optimized-spans)
          [(ErrCompilerBackend diag)
            (and
              (string-eq
                (compiler-diagnostic-message diag)
                "backend: f64 values are not supported yet")
              (= (compiler-diagnostic-line diag) 55)
              (= (compiler-diagnostic-col diag) 13))]
          [(OkCompilerBackend _) false])])))

(define (compiler-backend-instr-contains?
  [instr : CompilerIrInstr]
  [needle : String]) : bool
  (match (compiler-backend-emit-instr
    (BackendTargetLinux)
    "_tl_test"
    "test"
    IrBlockNil
    "entry"
    (CompilerBackendNoLabel)
    instr
    CompilerRegAssignmentNil
    8
    CompilerRegVarTypeNil
    (CompilerBackendGlobalTypeNil)
    (AstTyI64)
    (BackendRuntimePlan
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      (CompilerBackendRuntimeTailPlan false false))
    IrFunctionNil
    IrExternNil
    (compiler-backend-program-index-build IrFunctionNil IrExternNil)
    (compiler-source-spans-empty)
    (compiler-diagnostic-at-start "" ""))
    [(OkCompilerBackend asm) (compiler-backend-string-contains? asm needle)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-emit-test-instrs
  [instrs : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : ResultCompilerBackend
  (let
    [blocks : CompilerIrBlockList
      (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil)]
    [use-counts : (Array i64)
      (compiler-backend-function-use-counts vars blocks)]
    [_addr-forward : unit
      (compiler-backend-addr-of-forwarding-enable! vars blocks use-counts)]
    (match (compiler-backend-emit-instrs
      (BackendTargetLinux)
      "_tl_test"
      "test"
      blocks
      "entry"
      (CompilerBackendNoLabel)
      instrs
      assignments
      vars
      CompilerRegVarTypeNil
      (CompilerBackendGlobalTypeNil)
      (AstTyI64)
      (compiler-backend-runtime-helper-full-plan)
      IrFunctionNil
      IrExternNil
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)
      (compiler-source-spans-empty)
      (compiler-diagnostic-at-start "" "")
      use-counts
      (text-buf-empty))
      [(OkCompilerBackend asm)
        (let
          [_addr-forward-done : unit
            (compiler-backend-addr-of-forwarding-disable!)]
          (OkCompilerBackend asm))]
      [(ErrCompilerBackend message)
        (let
          [_addr-forward-done : unit
            (compiler-backend-addr-of-forwarding-disable!)]
          (ErrCompilerBackend message))])))

(define (compiler-backend-runtime-helper-full-plan) : CompilerBackendRuntimePlan
  (BackendRuntimePlan
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    true
    (CompilerBackendRuntimeTailPlan true true)))

(define (compiler-backend-runtime-helper-inventory-symbol-ok?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (and
    (compiler-backend-runtime-helper-known? name)
    (compiler-backend-plan-provides? plan name)))

(define (compiler-backend-runtime-helper-inventory-core-symbol-ok?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (and
    (compiler-backend-runtime-helper-inventory-symbol-ok? plan name)
    (match (compiler-backend-runtime-helper-owner name)
      [(BackendRuntimeOwnerCore) true]
      [_ false])))

(define (compiler-backend-runtime-helper-inventory-compat-alias-ok?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (and
    (compiler-backend-plan-provides? plan name)
    (match (compiler-backend-runtime-helper-owner name)
      [(BackendRuntimeOwnerCompatibilityAlias) true]
      [_ false])))

(define (compiler-backend-runtime-helper-inventory-core-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (and
    (backend-and8
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_alloc")
      (not (compiler-backend-runtime-helper-known? "tl_oob_abort"))
      (not (compiler-backend-runtime-helper-known? "tl_div_abort"))
      (not (compiler-backend-runtime-helper-known? "tl_shift_abort"))
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_abort")
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_region_mark")
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_region_reset")
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_arena_make"))
    (backend-and4
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_arena_current")
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_arena_set")
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_arena_destroy")
      (compiler-backend-runtime-helper-inventory-core-symbol-ok?
        plan
        "tl_arena_make_atomic"))
    (compiler-backend-runtime-helper-inventory-core-symbol-ok?
      plan
      "tl_arena_poison_enable")
    (compiler-backend-runtime-helper-inventory-core-symbol-ok?
      plan
      "tl_thread_init")))

(define (compiler-backend-runtime-helper-inventory-stdlib-ffi-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (backend-and4
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_profile_alloc_total")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_profile_alloc_live")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_profile_alloc_peak")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_profile_alloc_reset_peak")))

(define (compiler-backend-runtime-helper-inventory-stdlib-string-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (and
    (compiler-backend-runtime-helper-inventory-symbol-ok? plan "tl_substring")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_string_concat")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_string_concat3")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_string_concat4")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_string_concat5")
    (compiler-backend-runtime-helper-inventory-symbol-ok?
      plan
      "tl_int_to_string")))

(define (compiler-backend-runtime-helper-inventory-retired-string-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (backend-and4
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_string_eq")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_string_to_int")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_hash_string")
    true))

(define (compiler-backend-runtime-helper-inventory-env-compat-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (backend-and4
    (compiler-backend-runtime-helper-inventory-compat-alias-ok?
      plan
      "tl_env_var_exists")
    (compiler-backend-runtime-helper-inventory-compat-alias-ok?
      plan
      "tl_env_var_value")
    (compiler-backend-runtime-helper-inventory-compat-alias-ok?
      plan
      "env-path-separator")
    true))

(define (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (and
    (not (compiler-backend-runtime-helper-known? name))
    (not (compiler-backend-plan-provides? plan name))))

(define (compiler-backend-runtime-helper-inventory-retired-file-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (and
    (backend-and8
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_read_file")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_write_file")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_exists")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_read_file_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_write_file_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_append_file_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_exists_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_open_status"))
    (backend-and8
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_close_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_read_chunk_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_write_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_flush_status")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_read_chunk_bytes")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        ".L_tl_file_read_chunk_eof")
      true
      true)))

(define (compiler-backend-runtime-helper-inventory-retired-process-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (backend-and4
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_process_output")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_process_start")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_process_wait")
    true))

(define (compiler-backend-runtime-helper-inventory-retired-fs-metadata-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (backend-and4
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_fs_file_kind_status")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_fs_file_size_status")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_fs_file_size")
    true))

(define (compiler-backend-runtime-helper-inventory-retired-io-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (backend-and8
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_read_stdin_line")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_read_stdin_bytes")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_stdin_eof")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_flush_stdout")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_print_err")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_print_str")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_print_string")
    true))

(define (compiler-backend-runtime-helper-inventory-retired-compat-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (backend-and8
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_print_char")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_print_f64")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_arg_count")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      "tl_arg_count")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
      plan
      ".L_tl_arg")
    (compiler-backend-runtime-helper-inventory-retired-symbol-ok? plan "tl_arg")
    true
    (and
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        "tl_print_err")
      (compiler-backend-runtime-helper-inventory-retired-symbol-ok?
        plan
        "tl_print_string"))))

(define (compiler-backend-runtime-helper-inventory-negative-ok?
  [plan : CompilerBackendRuntimePlan]) : bool
  (and
    (not (compiler-backend-runtime-helper-known? "tl_profile_now_ms"))
    (not (compiler-backend-plan-provides? plan "tl_profile_now_ms"))
    (not (compiler-backend-runtime-helper-known? "tl_random_system_seed"))
    (not (compiler-backend-plan-provides? plan "tl_random_system_seed"))
    (not (compiler-backend-runtime-helper-known? "tl_cpuid_eax"))
    (not (compiler-backend-plan-provides? plan "tl_cpuid_eax"))
    (not (compiler-backend-runtime-helper-known? ".L_tl_fs_mkdir_status"))
    (not (compiler-backend-plan-provides? plan ".L_tl_fs_mkdir_status"))))

(define (compiler-backend-runtime-helper-owner-id-ok?) : bool
  (begin
    (compiler-builtin-refresh!)
    (let
      [core-id : i64 (compiler-backend-runtime-name-id "tl_alloc")]
      [profile-id : i64
        (compiler-backend-runtime-name-id "tl_profile_alloc_total")]
      [stdlib-id : i64 (compiler-backend-runtime-name-id "tl_string_concat")]
      [compat-id : i64 (compiler-backend-runtime-name-id "env-path-separator")]
      [retired-id : i64 (compiler-backend-runtime-name-id "tl_oob_abort")]
      (and
        (backend-and4
          (compiler-backend-runtime-helper-core-id? core-id)
          (compiler-backend-runtime-helper-stdlib-ffi-id? profile-id)
          (compiler-backend-runtime-helper-stdlib-type-lisp-id? stdlib-id)
          (compiler-backend-runtime-helper-compatibility-alias-id? compat-id))
        (not (compiler-backend-runtime-helper-known-id? retired-id))
        (compiler-builtin-backend-runtime-concat-id? stdlib-id)
        (compiler-builtin-backend-runtime-profile-id? profile-id)))))

(define (compiler-backend-intern-missing? [name : String]) : bool
  (match (intern-lookup name)
    [(InternLookupMissing) true]
    [(InternLookupFound _) false]))

(define (compiler-backend-runtime-plan-id-lookup-only-ok?) : bool
  (let
    [plan : CompilerBackendRuntimePlan
      (compiler-backend-runtime-helper-full-plan)]
    (begin
      (compiler-builtin-refresh!)
      (let
        [generation : i64 (intern-generation)]
        [unknown : String "tl_issue_2464_unknown_runtime_probe"]
        (and
          (compiler-backend-intern-missing? unknown)
          (compiler-backend-plan-provides? plan "tl_alloc")
          (compiler-backend-plan-provides? plan "tl_profile_alloc_total")
          (compiler-backend-plan-provides? plan "env-path-separator")
          (not (compiler-backend-runtime-helper-known? unknown))
          (match (compiler-backend-runtime-helper-owner unknown)
            [(BackendRuntimeOwnerUnknown) true]
            [_ false])
          (not (compiler-backend-plan-provides? plan unknown))
          (= (intern-generation) generation)
          (compiler-backend-intern-missing? unknown))))))

(define (compiler-backend-runtime-helper-inventory-ok?) : bool
  (let
    [plan : CompilerBackendRuntimePlan
      (compiler-backend-runtime-helper-full-plan)]
    (backend-and8
      (compiler-backend-runtime-helper-inventory-core-ok? plan)
      (compiler-backend-runtime-helper-inventory-stdlib-ffi-ok? plan)
      (compiler-backend-runtime-helper-inventory-stdlib-string-ok? plan)
      (compiler-backend-runtime-helper-inventory-env-compat-ok? plan)
      (compiler-backend-runtime-helper-inventory-retired-file-ok? plan)
      (compiler-backend-runtime-helper-inventory-retired-io-ok? plan)
      (compiler-backend-runtime-helper-inventory-retired-compat-ok? plan)
      (and
        (compiler-backend-runtime-helper-inventory-retired-process-ok? plan)
        (compiler-backend-runtime-helper-inventory-retired-fs-metadata-ok? plan)
        (compiler-backend-runtime-helper-inventory-retired-string-ok? plan)
        (compiler-backend-runtime-helper-inventory-negative-ok? plan)
        (compiler-backend-runtime-helper-owner-id-ok?)
        (compiler-backend-runtime-plan-id-lookup-only-ok?)))))

(define (compiler-backend-runtime-page-call-inventory-linux-ok?) : bool
  (let
    [asm : String
      (compiler-backend-runtime-functions-for-target
        (BackendTargetLinux)
        (compiler-backend-runtime-helper-full-plan))]
    (and
      (backend-and8
        (compiler-backend-string-contains? asm "tl_alloc:\n")
        (compiler-backend-string-contains? asm "tl_region_mark:\n")
        (compiler-backend-string-contains? asm "tl_region_reset:\n")
        (compiler-backend-string-contains? asm "tl_arena_make:\n")
        (compiler-backend-string-contains? asm "tl_arena_current:\n")
        (compiler-backend-string-contains? asm "tl_arena_set:\n")
        (compiler-backend-string-contains? asm "tl_arena_destroy:\n")
        (compiler-backend-string-contains? asm "tl_arena_poison_enable:\n"))
      (compiler-backend-string-contains? asm "tl_arena_make_atomic:\n")
      (backend-and4
        (=
          (compiler-backend-string-count asm "    movq $9, %rax\n    syscall\n")
          5)
        (=
          (compiler-backend-string-count
            asm
            "    movq $11, %rax\n    syscall\n")
          4)
        (= (compiler-backend-string-count asm "    syscall\n") 13)
        (=
          (compiler-backend-string-count
            asm
            "    movq $60, %rax\n    movq $134, %rdi\n    syscall\n")
          3))
      (compiler-backend-string-contains?
        asm
        "    movq $158, %rax\n    syscall\n")
      (not (compiler-backend-string-contains? asm "VirtualAlloc"))
      (not (compiler-backend-string-contains? asm "VirtualFree")))))

(define (compiler-backend-runtime-page-call-inventory-windows-ok?) : bool
  (let
    [asm : String
      (compiler-backend-runtime-functions-for-target
        (BackendTargetWindows)
        (compiler-backend-runtime-helper-full-plan))]
    (and
      (backend-and8
        (compiler-backend-string-contains? asm "tl_alloc:\n")
        (compiler-backend-string-contains? asm "tl_region_mark:\n")
        (compiler-backend-string-contains? asm "tl_region_reset:\n")
        (compiler-backend-string-contains? asm "tl_arena_make:\n")
        (compiler-backend-string-contains? asm "tl_arena_current:\n")
        (compiler-backend-string-contains? asm "tl_arena_set:\n")
        (compiler-backend-string-contains? asm "tl_arena_destroy:\n")
        (compiler-backend-string-contains? asm "tl_arena_poison_enable:\n"))
      (compiler-backend-string-contains? asm "tl_arena_make_atomic:\n")
      (backend-and4
        (= (compiler-backend-string-count asm "    call VirtualAlloc\n") 4)
        (= (compiler-backend-string-count asm "    call VirtualFree\n") 4)
        (not (compiler-backend-string-contains? asm "    syscall\n"))
        (not (compiler-backend-string-contains? asm "    call WriteFile\n")))
      (compiler-backend-string-contains? asm "    movq %gs:0x28, %r8\n")
      (not (compiler-backend-string-contains? asm "    call _write\n"))
      (not (compiler-backend-string-contains? asm "SystemFunction036")))))

(define (compiler-backend-runtime-page-call-inventory-ok?) : bool
  (and
    (compiler-backend-runtime-page-call-inventory-linux-ok?)
    (compiler-backend-runtime-page-call-inventory-windows-ok?)))

(define (compiler-backend-memory-op-ok?) : bool
  (and
    (compiler-backend-instr-contains?
      (IrInstrAddrOf 2 1)
      "    leaq -16(%rbp), %rax\n")
    (compiler-backend-instr-contains?
      (IrInstrGep 3 (IrValueVar 1) (IrValueI64 2) (AstTyI32))
      "    addq $8, %rax\n")
    (compiler-backend-instr-contains?
      (IrInstrGep 3 (IrValueVar 1) (IrValueVar 2) (AstTyI32))
      "    leaq (%rax,%r8,4), %rax\n")
    (compiler-backend-instr-contains?
      (IrInstrLoad 4 (IrValueVar 1) (AstTyU8))
      "    movzbq (%r10), %rax\n")
    (compiler-backend-instr-contains?
      (IrInstrStorePtr (IrValueVar 1) (IrValueI64 7) (AstTyI32))
      "    movl $7, (%r10)\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyI8) (AstTyI64))
      "    movsbq -48(%rbp), %rax\n")
    (compiler-backend-instr-contains?
      (IrInstrBoundsCheck (IrValueVar 1) (IrValueVar 2) "bounds_ok")
      "    jb .L_tl_test_bounds_ok\n")))

(define (compiler-backend-addr-of-forwarding-shape-ok?) : bool
  (match (compiler-backend-emit-test-instrs
    (compiler-ir-instr-cons
      (IrInstrAddrOf 2 1)
      (compiler-ir-instr-cons
        (IrInstrStorePtr (IrValueVar 2) (IrValueI64 7) (AstTyI64))
        IrInstrNil))
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 2 (CompilerRegRegister "%r12"))
      CompilerRegAssignmentNil)
    4)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    leaq -16(%rbp), %r10\n")
        (compiler-backend-string-contains? asm "    movq $7, (%r10)\n")
        (not (compiler-backend-string-contains? asm "%r12"))
        (not
          (compiler-backend-string-contains? asm "    movq %rax, -24(%rbp)\n"))
        (not
          (compiler-backend-string-contains? asm "    movq -24(%rbp), %r10\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-addr-of-register-home-shape-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r12"))
        CompilerRegAssignmentNil)]
    (match (compiler-backend-emit-addr-of assignments 2 1)
      [(OkCompilerBackend asm) (string-eq asm "    leaq -16(%rbp), %r12\n")]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-gep-copy-bytes-const-shape-ok?) : bool
  (match (compiler-backend-emit-test-instrs
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 0) (IrValueI64 1) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrCopyBytes (IrValueVar 2) (IrValueVar 1) 24)
        IrInstrNil))
    CompilerRegAssignmentNil
    5)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movq -8(%rbp), %r10\n")
        (compiler-backend-string-contains? asm "    addq $8, %r10\n")
        (compiler-backend-string-contains? asm "    movq -16(%rbp), %r11\n")
        (compiler-backend-string-contains? asm "    movups (%r11), %xmm15\n")
        (not
          (compiler-backend-string-contains? asm "    movq %rax, -24(%rbp)\n"))
        (not
          (compiler-backend-string-contains? asm "    movq -24(%rbp), %r10\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-gep-copy-bytes-index-shape-ok?) : bool
  (match (compiler-backend-emit-test-instrs
    (compiler-ir-instr-cons
      (IrInstrGep 3 (IrValueVar 0) (IrValueVar 2) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrCopyBytes (IrValueVar 3) (IrValueVar 1) 16)
        IrInstrNil))
    CompilerRegAssignmentNil
    6)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movq -8(%rbp), %r10\n")
        (compiler-backend-string-contains? asm "    movq -24(%rbp), %r8\n")
        (compiler-backend-string-contains? asm "    leaq (%r10,%r8,8), %r10\n")
        (compiler-backend-string-contains? asm "    movq -16(%rbp), %r11\n")
        (not
          (compiler-backend-string-contains? asm "    movq %rax, -32(%rbp)\n"))
        (not
          (compiler-backend-string-contains? asm "    movq -32(%rbp), %r10\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-gep-load-r10-reuse-shape-ok?) : bool
  (match (compiler-backend-emit-test-instrs
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 0) (IrValueI64 0) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 2) (AstTyU64))
        (compiler-ir-instr-cons
          (IrInstrGep 4 (IrValueVar 0) (IrValueI64 1) (AstTyU64))
          (compiler-ir-instr-cons
            (IrInstrLoad 5 (IrValueVar 4) (AstTyU64))
            IrInstrNil))))
    CompilerRegAssignmentNil
    7)
    [(OkCompilerBackend asm)
      (and
        (= (compiler-backend-string-count asm "    movq -8(%rbp), %r10\n") 1)
        (compiler-backend-string-contains? asm "    movq (%r10), %rax\n")
        (compiler-backend-string-contains? asm "    movq 8(%r10), %rax\n")
        (not
          (compiler-backend-string-contains? asm "    movq -40(%rbp), %r10\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-gep-load-compare-priority-shape-ok?) : bool
  (match (compiler-backend-emit-test-instrs
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 0) (IrValueI64 0) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 2) (AstTyU64))
        (compiler-ir-instr-cons
          (IrInstrGep 4 (IrValueVar 0) (IrValueI64 1) (AstTyU64))
          (compiler-ir-instr-cons
            (IrInstrLoad 5 (IrValueVar 4) (AstTyU64))
            (compiler-ir-instr-cons
              (IrInstrBinOp
                7
                (IrBinEq)
                (IrValueVar 5)
                (IrValueVar 6)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 7) "eq" "ne")
                IrInstrNil))))))
    CompilerRegAssignmentNil
    9)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    cmpq %r8, 8(%r10)\n")
        (not (compiler-backend-string-contains? asm "    movq 8(%r10), %rax\n"))
        (not
          (compiler-backend-string-contains? asm "    movq %rax, -48(%rbp)\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-load-load-pointer-chase-shape-ok?) : bool
  (match (compiler-backend-emit-test-instrs
    (compiler-ir-instr-cons
      (IrInstrLoad 1 (IrValueVar 0) (ast-ty-mut-ptr (AstTyU8)))
      (compiler-ir-instr-cons
        (IrInstrLoad 2 (IrValueVar 1) (AstTyI64))
        IrInstrNil))
    CompilerRegAssignmentNil
    4)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movq -8(%rbp), %r10\n")
        (compiler-backend-string-contains? asm "    movq (%r10), %r10\n")
        (compiler-backend-string-contains? asm "    movq (%r10), %rax\n")
        (not
          (compiler-backend-string-contains? asm "    movq %rax, -16(%rbp)\n"))
        (not
          (compiler-backend-string-contains? asm "    movq -16(%rbp), %r10\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-store-ptr-pair-shape-ok?) : bool
  (match (compiler-backend-emit-test-instrs
    (compiler-ir-instr-cons
      (IrInstrStorePtr (IrValueVar 0) (IrValueI64 1) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrGep 2 (IrValueVar 0) (IrValueI64 1) (AstTyU64))
        (compiler-ir-instr-cons
          (IrInstrStorePtr (IrValueVar 2) (IrValueI64 2) (AstTyI64))
          IrInstrNil)))
    CompilerRegAssignmentNil
    4)
    [(OkCompilerBackend asm)
      (and
        (= (compiler-backend-string-count asm "    movq -8(%rbp), %r10\n") 1)
        (compiler-backend-string-contains? asm "    movq $1, (%r10)\n")
        (compiler-backend-string-contains? asm "    movq $2, 8(%r10)\n")
        (not
          (compiler-backend-string-contains? asm "    movq %rax, -24(%rbp)\n"))
        (not
          (compiler-backend-string-contains? asm "    movq -24(%rbp), %r10\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-store-home-base-shape-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        CompilerRegAssignmentNil)]
    [index : CompilerBackendProgramIndex
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)]
    (and
      (match (compiler-backend-emit-store-ptr
        assignments
        (IrValueVar 0)
        (IrValueI64 7)
        (AstTyI64)
        index)
        [(OkCompilerBackend asm)
          (and
            (string-eq asm "    movq $7, (%r12)\n")
            (not (compiler-backend-string-contains? asm "%r10")))]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-store-to-gep
        assignments
        (IrValueVar 0)
        (IrValueI64 1)
        (AstTyU64)
        (IrValueI64 9)
        (AstTyI64)
        index)
        [(OkCompilerBackend asm)
          (and
            (string-eq asm "    movq $9, 8(%r12)\n")
            (not (compiler-backend-string-contains? asm "%r10")))]
        [(ErrCompilerBackend _) false]))))

(define (compiler-backend-copy-bytes-direct-home-shape-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
          CompilerRegAssignmentNil))]
    (match (compiler-backend-emit-test-instrs
      (compiler-ir-instr-cons
        (IrInstrCopyBytes (IrValueVar 0) (IrValueVar 1) 24)
        IrInstrNil)
      assignments
      3)
      [(OkCompilerBackend asm)
        (and
          (backend-and4
            (compiler-backend-string-contains?
              asm
              "    movups (%r13), %xmm15\n")
            (compiler-backend-string-contains?
              asm
              "    movups %xmm15, (%r12)\n")
            (compiler-backend-string-contains? asm "    movq 16(%r13), %rax\n")
            (compiler-backend-string-contains? asm "    movq %rax, 16(%r12)\n"))
          (not (compiler-backend-string-contains? asm "    movq %r12, %r10\n"))
          (not (compiler-backend-string-contains? asm "    movq %r13, %r11\n")))]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-widening-cast-direct-home-shape-ok?) : bool
  (let
    [index : CompilerBackendProgramIndex
      (compiler-backend-program-index-build IrFunctionNil IrExternNil)]
    [reg-src : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 5 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 6 (CompilerRegRegister "%rbx"))
          CompilerRegAssignmentNil))]
    [stack-src : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 6 (CompilerRegRegister "%rbx"))
        CompilerRegAssignmentNil)]
    (and
      (match (compiler-backend-emit-cast
        "_tl_test"
        "entry"
        reg-src
        6
        (IrValueVar 5)
        (AstTyI8)
        (AstTyI64)
        index)
        [(OkCompilerBackend asm) (string-eq asm "    movsbq %r12b, %rbx\n")]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-cast
        "_tl_test"
        "entry"
        stack-src
        6
        (IrValueVar 5)
        (AstTyU8)
        (AstTyU64)
        index)
        [(OkCompilerBackend asm) (string-eq asm "    movzbq -48(%rbp), %rbx\n")]
        [(ErrCompilerBackend _) false]))))

(define (compiler-backend-global-store-direct-home-shape-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        CompilerRegAssignmentNil)]
    (match (compiler-backend-emit-test-instrs
      (compiler-ir-instr-cons
        (IrInstrStore "g" (IrValueVar 0) (AstTyI32))
        IrInstrNil)
      assignments
      2)
      [(OkCompilerBackend asm)
        (and
          (compiler-backend-string-contains? asm "    movq %r12, _tl_g(%rip)\n")
          (not (compiler-backend-string-contains? asm "    movq %r12, %rax\n"))
          (not
            (compiler-backend-string-contains?
              asm
              "    movq %rax, _tl_g(%rip)\n")))]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-pack-direct-home-shape-ok?) : bool
  (let
    [ty : AstType (compiler-backend-register-group-test-type)]
    [index : CompilerBackendProgramIndex
      (compiler-backend-register-group-test-index)]
    [words : CompilerIrValueList
      (compiler-ir-value-cons
        (IrValueVar 0)
        (compiler-ir-value-cons (IrValueVar 1) IrValueNil))]
    [direct-assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 1 (CompilerRegRegister "%rbx"))
          (compiler-reg-assignment-cons
            (CompilerRegAssignment 2 (CompilerRegRegisterPair "%r14" "%r15"))
            CompilerRegAssignmentNil)))]
    [noop-assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r14"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 1 (CompilerRegRegister "%r15"))
          (compiler-reg-assignment-cons
            (CompilerRegAssignment 2 (CompilerRegRegisterPair "%r14" "%r15"))
            CompilerRegAssignmentNil)))]
    [diag : CompilerDiagnostic (compiler-diagnostic-at-start "" "")]
    (and
      (match (compiler-backend-emit-pack
        direct-assignments
        2
        words
        ty
        4
        index
        diag)
        [(OkCompilerBackend asm)
          (string-eq asm "    movq %r12, %r14\n    movq %rbx, %r15\n")]
        [(ErrCompilerBackend _) false])
      (match (compiler-backend-emit-pack
        noop-assignments
        2
        words
        ty
        4
        index
        diag)
        [(OkCompilerBackend asm) (string-eq asm "")]
        [(ErrCompilerBackend _) false]))))

(define (compiler-backend-scratch-staging-direct-home-shape-ok?) : bool
  (backend-and4
    (compiler-backend-copy-bytes-direct-home-shape-ok?)
    (compiler-backend-widening-cast-direct-home-shape-ok?)
    (compiler-backend-global-store-direct-home-shape-ok?)
    (compiler-backend-pack-direct-home-shape-ok?)))

(define (compiler-backend-address-mode-fusion-ok?) : bool
  (and
    (backend-and8
      (compiler-backend-addr-of-forwarding-shape-ok?)
      (compiler-backend-addr-of-register-home-shape-ok?)
      (compiler-backend-gep-copy-bytes-const-shape-ok?)
      (compiler-backend-gep-copy-bytes-index-shape-ok?)
      (compiler-backend-gep-load-r10-reuse-shape-ok?)
      (compiler-backend-load-load-pointer-chase-shape-ok?)
      (compiler-backend-store-ptr-pair-shape-ok?)
      (compiler-backend-store-home-base-shape-ok?))
    (compiler-backend-gep-load-compare-priority-shape-ok?)))

(define (compiler-backend-full-syscall-instr) : CompilerIrInstr
  (IrInstrSyscall
    0
    (compiler-ir-call-args-from-list
      (compiler-ir-value-cons
        (IrValueI64 231)
        (compiler-ir-value-cons
          (IrValueI64 1)
          (compiler-ir-value-cons
            (IrValueI64 2)
            (compiler-ir-value-cons
              (IrValueI64 3)
              (compiler-ir-value-cons
                (IrValueI64 4)
                (compiler-ir-value-cons
                  (IrValueI64 5)
                  (compiler-ir-value-cons (IrValueI64 6) IrValueNil))))))))))

(define (compiler-backend-full-syscall-registers-ok?) : bool
  (let
    [instr : CompilerIrInstr (compiler-backend-full-syscall-instr)]
    (and
      (backend-and8
        (compiler-backend-instr-contains? instr "    movl $231, %eax\n")
        (compiler-backend-instr-contains? instr "    movl $1, %edi\n")
        (compiler-backend-instr-contains? instr "    movl $2, %esi\n")
        (compiler-backend-instr-contains? instr "    movl $3, %edx\n")
        (compiler-backend-instr-contains? instr "    movl $4, %r10d\n")
        (compiler-backend-instr-contains? instr "    movl $5, %r8d\n")
        (compiler-backend-instr-contains? instr "    movl $6, %r9d\n")
        (compiler-backend-instr-contains? instr "    syscall\n"))
      (not (compiler-backend-instr-contains? instr "    pushq %rax\n"))
      (not (compiler-backend-instr-contains? instr "    popq ")))))

(define (compiler-backend-entry-load-register-homes-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 1 (CompilerRegRegister "%r13"))
          (compiler-reg-assignment-cons
            (CompilerRegAssignment 2 (CompilerRegRegister "%r14"))
            CompilerRegAssignmentNil)))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (IrInstrEntryArgc 0)
        (compiler-ir-instr-cons
          (IrInstrEntryArgv 1)
          (compiler-ir-instr-cons (IrInstrEntryEnvp 2) IrInstrNil)))]
    (match (compiler-backend-emit-test-instrs instrs assignments 3)
      [(OkCompilerBackend asm)
        (and
          (backend-and4
            (compiler-backend-string-contains?
              asm
              "    movq .L_tl_argc(%rip), %r12\n")
            (compiler-backend-string-contains?
              asm
              "    movq .L_tl_argv(%rip), %r13\n")
            (compiler-backend-string-contains?
              asm
              "    movq .L_tl_envp(%rip), %r14\n")
            (not
              (compiler-backend-string-contains?
                asm
                "    movq .L_tl_argc(%rip), %rax\n")))
          (backend-and4
            (not
              (compiler-backend-string-contains?
                asm
                "    movq .L_tl_argv(%rip), %rax\n"))
            (not
              (compiler-backend-string-contains?
                asm
                "    movq .L_tl_envp(%rip), %rax\n"))
            (not
              (compiler-backend-string-contains? asm "    movq %rax, %r12\n"))
            (not
              (compiler-backend-string-contains? asm "    movq %rax, %r13\n")))
          (not (compiler-backend-string-contains? asm "    movq %rax, %r14\n")))]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-entry-load-fallbacks-ok?) : bool
  (let
    [spill-assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegSpill -16))
        CompilerRegAssignmentNil)]
    [pair-assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-cons
        (CompilerRegAssignment 0 (CompilerRegRegisterPair "%r12" "%r13"))
        CompilerRegAssignmentNil)]
    [no-location-ok? : bool
      (match (compiler-backend-emit-test-instrs
        (compiler-ir-instr-cons (IrInstrEntryArgc 0) IrInstrNil)
        CompilerRegAssignmentNil
        1)
        [(OkCompilerBackend asm)
          (and
            (compiler-backend-string-contains?
              asm
              "    movq .L_tl_argc(%rip), %rax\n")
            (compiler-backend-string-contains? asm "    movq %rax, -8(%rbp)\n"))]
        [(ErrCompilerBackend _) false])]
    [spill-ok? : bool
      (match (compiler-backend-emit-test-instrs
        (compiler-ir-instr-cons (IrInstrEntryArgv 0) IrInstrNil)
        spill-assignments
        1)
        [(OkCompilerBackend asm)
          (and
            (compiler-backend-string-contains?
              asm
              "    movq .L_tl_argv(%rip), %rax\n")
            (compiler-backend-string-contains? asm "    movq %rax, -16(%rbp)\n"))]
        [(ErrCompilerBackend _) false])]
    [pair-ok? : bool
      (match (compiler-backend-emit-test-instrs
        (compiler-ir-instr-cons (IrInstrEntryEnvp 0) IrInstrNil)
        pair-assignments
        1)
        [(OkCompilerBackend asm)
          (and
            (compiler-backend-string-contains?
              asm
              "    movq .L_tl_envp(%rip), %rax\n")
            (compiler-backend-string-contains? asm "    movq %rax, %r12\n")
            (not
              (compiler-backend-string-contains?
                asm
                "    movq .L_tl_envp(%rip), %r12\n")))]
        [(ErrCompilerBackend _) false])]
    (and no-location-ok? spill-ok? pair-ok?)))

(define (compiler-backend-cpuid-eax-direct-ok?) : bool
  (let
    [instr : CompilerIrInstr (IrInstrCpuId 0 (IrValueI64 7) (IrValueI64 0) 0)]
    (backend-and8
      (compiler-backend-instr-contains? instr "    xorl %ecx, %ecx\n")
      (compiler-backend-instr-contains? instr "    movl $7, %eax\n")
      (compiler-backend-instr-contains? instr "    pushq %rbx\n")
      (compiler-backend-instr-contains? instr "    cpuid\n")
      (compiler-backend-instr-contains? instr "    popq %rbx\n")
      (not (compiler-backend-instr-contains? instr "    movl %eax, %eax\n"))
      (not (compiler-backend-instr-contains? instr "    movl %r11d, %ecx\n"))
      (not (compiler-backend-instr-contains? instr "%r11")))))

(define (compiler-backend-cpuid-direct-subleaf-ok?) : bool
  (let
    [instr : CompilerIrInstr (IrInstrCpuId 0 (IrValueI64 7) (IrValueI64 3) 0)]
    (backend-and4
      (compiler-backend-instr-contains? instr "    movl $3, %ecx\n")
      (compiler-backend-instr-contains? instr "    movl $7, %eax\n")
      (not (compiler-backend-instr-contains? instr "    movl %r11d, %ecx\n"))
      (not (compiler-backend-instr-contains? instr "%r11")))))

(define (compiler-backend-xgetbv-zero-index-ok?) : bool
  (let
    [instr : CompilerIrInstr (IrInstrXgetbv 0 (IrValueI64 0))]
    (backend-and4
      (compiler-backend-instr-contains? instr "    xorl %ecx, %ecx\n")
      (compiler-backend-instr-contains? instr "    xgetbv\n")
      (compiler-backend-instr-contains? instr "    orq %rdx, %rax\n")
      true)))

(define (compiler-backend-low-level-instr-ok?) : bool
  (and
    (backend-and8
      (compiler-backend-instr-contains? (IrInstrEntryArgc 0) ".L_tl_argc(%rip)")
      (compiler-backend-instr-contains? (IrInstrEntryArgv 0) ".L_tl_argv(%rip)")
      (compiler-backend-instr-contains? (IrInstrEntryEnvp 0) ".L_tl_envp(%rip)")
      (compiler-backend-cpuid-eax-direct-ok?)
      (compiler-backend-instr-contains?
        (IrInstrCpuId 0 (IrValueI64 7) (IrValueI64 0) 1)
        "    movl %ebx, %eax\n")
      (compiler-backend-instr-contains?
        (IrInstrCpuId 0 (IrValueI64 7) (IrValueI64 0) 2)
        "    movl %ecx, %eax\n")
      (compiler-backend-instr-contains?
        (IrInstrCpuId 0 (IrValueI64 7) (IrValueI64 0) 3)
        "    movl %edx, %eax\n")
      (compiler-backend-xgetbv-zero-index-ok?))
    (compiler-backend-cpuid-direct-subleaf-ok?)
    (backend-and8
      ;; A one-operand syscall loads the number into %rax and issues `syscall`.
      (compiler-backend-instr-contains?
        (IrInstrSyscall 0 (IrCallArgsOne (IrValueI64 231)))
        "    movl $231, %eax\n")
      (compiler-backend-instr-contains?
        (IrInstrSyscall 0 (IrCallArgsOne (IrValueI64 231)))
        "    syscall\n")
      (not
        (compiler-backend-instr-contains?
          (IrInstrSyscall 0 (IrCallArgsOne (IrValueI64 231)))
          "    pushq %rax\n"))
      (not
        (compiler-backend-instr-contains?
          (IrInstrSyscall 0 (IrCallArgsOne (IrValueI64 231)))
          "    popq "))
      ;; A two-operand syscall additionally loads argument 0 into %rdi.
      (compiler-backend-instr-contains?
        (IrInstrSyscall 0 (IrCallArgsTwo (IrValueI64 231) (IrValueI64 42)))
        "    movl $42, %edi\n")
      (compiler-backend-instr-contains?
        (IrInstrSyscall 0 (IrCallArgsTwo (IrValueI64 231) (IrValueI64 42)))
        "    movl $231, %eax\n")
      (compiler-backend-instr-contains?
        (IrInstrSyscall 0 (IrCallArgsTwo (IrValueI64 231) (IrValueI64 0)))
        "    xorl %edi, %edi\n")
      (compiler-backend-full-syscall-registers-ok?))
    (compiler-backend-entry-load-register-homes-ok?)
    (compiler-backend-entry-load-fallbacks-ok?)))

(define (compiler-backend-numeric-cast-shape-ok?) : bool
  (backend-and8
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyI64) (AstTyF64))
      "    cvtsi2sdq %rax, %xmm0\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyI64) (AstTyF32))
      "    cvtsi2ssq %rax, %xmm0\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyU8) (AstTyF64))
      "    cvtsi2sdq %rax, %xmm0\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyU64) (AstTyF64))
      "    js .L_tl_test_cast_u64_float_entry_v6_high\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyU64) (AstTyF32))
      "    addss %xmm0, %xmm0\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyF64) (AstTyI64))
      "    cvttsd2siq %xmm0, %rax\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyF64) (AstTyF32))
      "    cvtsd2ss %xmm0, %xmm0\n")
    (compiler-backend-instr-contains?
      (IrInstrCast 6 (IrValueVar 5) (AstTyF32) (AstTyF64))
      "    cvtss2sd %xmm0, %xmm0\n")))

(define (compiler-backend-bitcast-shape-ok?) : bool
  (and
    (backend-and4
      (compiler-backend-instr-contains?
        (IrInstrBitcast 6 (IrValueVar 5) (AstTyF32) (AstTyU64))
        "    movd %xmm0, %eax\n")
      (compiler-backend-instr-contains?
        (IrInstrBitcast 6 (IrValueVar 5) (AstTyU64) (AstTyF32))
        "    movd %eax, %xmm0\n")
      (compiler-backend-instr-contains?
        (IrInstrBitcast 6 (IrValueVar 5) (AstTyF64) (AstTyU64))
        "    movq %xmm0, %rax\n")
      (compiler-backend-instr-contains?
        (IrInstrBitcast 6 (IrValueVar 5) (AstTyU64) (AstTyF64))
        "    movq %rax, %xmm0\n"))
    (not
      (compiler-backend-instr-contains?
        (IrInstrBitcast 6 (IrValueVar 5) (AstTyF64) (AstTyF32))
        "unsupported bitcast"))))

;; A source exercising `array-ref`, used to confirm the lowerer's bounds-check
;; trap (#528) reaches the backend as a `call tl_oob_abort`.
(define (compiler-backend-array-access-source) : String
  "(define (get [a : (Array i64)] [i : i64]) : i64 (array-ref a i))
(define (main) : i64 0)")

(define (compiler-backend-array-access-asm-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-array-access-source))
    [(OkCompilerBackend asm)
      (compiler-backend-string-contains? asm "call tl_oob_abort")]
    [(ErrCompilerBackend _) false]))

;; Fixed-size array set/ref emit-shape coverage (#1416). The source takes the
;; fixed array as a parameter because fixed-array literals still have separate
;; lowerer coverage; this exercises backend emission for fixed-array indexing.
(define (compiler-backend-fixed-array-source) : String
  "(define (use-fixed [a : (Array i64 3)]) : i64
  (begin
    (array-set! a 0 42)
    (array-ref a 0)))
(define (main) : i64 0)")

(define (compiler-backend-fixed-array-shape-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-fixed-array-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (or
            (compiler-backend-string-contains? asm "_tl_use_fixed")
            (compiler-backend-string-contains? asm "_tl_f"))
          (compiler-backend-string-contains? asm "    cmpq $3, %rax\n")
          (not (compiler-backend-string-contains? asm "    movl $3, %r11d\n"))
          (compiler-backend-string-contains? asm "    call tl_oob_abort\n")
          (compiler-backend-string-contains?
            asm
            "    movq %rax, (%r10,%r8,8)\n")
          (compiler-backend-string-contains?
            asm
            "    movq (%r10,%r8,8), %rax\n")
          (not
            (compiler-backend-string-contains?
              asm
              "    leaq (%rax,%r8,8), %rax\n"))
          (not (compiler-backend-string-contains? asm "tl_oob_abort:\n")))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-make-array-source) : String
  "(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 2)]
    (begin
      (array-set! a 0 40)
      (array-set! a 1 2)
      (+ (array-ref a 0) (array-ref a 1)))))")

(define (compiler-backend-make-array-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-make-array-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "main:\n")
        (compiler-backend-string-contains? asm "    call tl_alloc\n")
        (compiler-backend-string-contains? asm "call tl_oob_abort")
        (compiler-backend-string-contains? asm "make_array_len_ok"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-region-source) : String
  "(define (int->string [value : i64]) : String
  \"41\")
(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (string-length s))))")

(define (compiler-backend-region-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-region-source))
    [(OkCompilerBackend asm)
      (let
        [calls : bool
          (and
            (compiler-backend-string-contains? asm "    call tl_region_mark\n")
            (compiler-backend-string-contains? asm "    call tl_region_reset\n"))]
        [runtime : bool
          (backend-and4
            (compiler-backend-string-contains? asm "tl_region_mark:\n")
            (compiler-backend-string-contains? asm "tl_region_reset:\n")
            (compiler-backend-string-contains? asm ".L_tl_region_reset_msg:")
            (compiler-backend-string-contains? asm "tl_current_arena:\n"))]
        [poison : bool
          (backend-and8
            (compiler-backend-string-contains?
              asm
              ".L_tl_arena_poison_enabled:\n")
            (compiler-backend-string-contains? asm "tl_arena_poison_enable:\n")
            (compiler-backend-string-contains?
              asm
              "    movq $1, .L_tl_arena_poison_enabled(%rip)\n")
            (compiler-backend-string-contains?
              asm
              ".L_tl_region_reset_drop_newer_retire:\n")
            (compiler-backend-string-contains?
              asm
              ".L_tl_region_reset_restore_set:\n")
            (compiler-backend-string-contains?
              asm
              ".L_tl_region_reset_all_unmap:\n")
            (compiler-backend-string-contains? asm "    movb $0xA5, %al\n")
            (>= (compiler-backend-string-count asm "    rep stosb\n") 4))]
        [no-externs : bool
          (and
            (not
              (compiler-backend-string-contains? asm ".extern tl_region_mark\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_region_reset\n")))]
        (backend-and4 calls runtime poison no-externs))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-process-output-source) : String
  "(extern (tl_process_output [arg0 : i64]) : i64)
(define (main) : i64 (tl_process_output 0))")

(define (compiler-backend-process-async-source) : String
  "(extern (tl_process_start [arg0 : i64]) : i64)
(extern (tl_process_wait [arg0 : i64]) : i64)
(define (main) : i64 (+ (tl_process_start 0) (tl_process_wait 0)))")

(define (compiler-backend-process-fallback-labels-absent? [asm : String]) : bool
  (and
    (backend-and8
      (not (compiler-backend-string-contains? asm "tl_process_output:\n"))
      (not (compiler-backend-string-contains? asm "tl_process_start:\n"))
      (not (compiler-backend-string-contains? asm "tl_process_wait:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_process_read_all:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_process_exec_marker:"))
      (not (compiler-backend-string-contains? asm "tmpfile:\n"))
      (not (compiler-backend-string-contains? asm "_fileno:\n"))
      (not (compiler-backend-string-contains? asm "_get_osfhandle:\n")))
    (backend-and4
      (not (compiler-backend-string-contains? asm "fclose:\n"))
      (not (compiler-backend-string-contains? asm "__p__environ:\n"))
      (not (compiler-backend-string-contains? asm "    call _lseeki64\n"))
      (not (compiler-backend-string-contains? asm "    call _read\n")))))

(define (compiler-backend-process-output-fallback-absent-asm-ok? [asm : String]) : bool
  (and
    (compiler-backend-process-fallback-labels-absent? asm)
    (compiler-backend-string-contains? asm ".extern tl_process_output\n")
    (compiler-backend-string-contains? asm "    call tl_process_output\n")
    (not (compiler-backend-string-contains? asm "_tl_tl_process_output"))))

(define (compiler-backend-process-async-fallback-absent-asm-ok? [asm : String]) : bool
  (and
    (compiler-backend-process-fallback-labels-absent? asm)
    (backend-and4
      (compiler-backend-string-contains? asm ".extern tl_process_start\n")
      (compiler-backend-string-contains? asm ".extern tl_process_wait\n")
      (compiler-backend-string-contains? asm "    call tl_process_start\n")
      (compiler-backend-string-contains? asm "    call tl_process_wait\n"))
    (not (compiler-backend-string-contains? asm "_tl_tl_process_start"))
    (not (compiler-backend-string-contains? asm "_tl_tl_process_wait"))))

(define (compiler-backend-process-fallback-absent-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-process-output-source))
    [(OkCompilerBackend output-asm)
      (match (compiler-backend-emit-source
        (compiler-backend-process-async-source))
        [(OkCompilerBackend async-asm)
          (and
            (compiler-backend-process-output-fallback-absent-asm-ok? output-asm)
            (compiler-backend-process-async-fallback-absent-asm-ok? async-asm))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-process-fallback-absent-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-process-output-source)
    (BackendTargetWindows))
    [(OkCompilerBackend output-asm)
      (match (compiler-backend-emit-source-for-target
        (compiler-backend-process-async-source)
        (BackendTargetWindows))
        [(OkCompilerBackend async-asm)
          (and
            (compiler-backend-process-output-fallback-absent-asm-ok? output-asm)
            (compiler-backend-process-async-fallback-absent-asm-ok? async-asm))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-env-runtime-source) : String
  "(extern (env-var-exists? [arg0 : String]) : bool (:symbol \"tl_env_var_exists\"))
(extern (env-var-value [arg0 : String]) : String (:symbol \"tl_env_var_value\"))
(extern (env-path-separator) : String)
(define (main) : i64
  (if (env-var-exists? \"TYPELISP_TEST_ENV\")
    (string-length (env-var-value \"TYPELISP_TEST_ENV\"))
    (string-length (env-path-separator))))")

;; Environment helpers are no longer emitted as backend asm — `stdlib/env.tl`
;; implements them in TypeLisp (#2142 follow-up). A program that externs the
;; legacy `tl_env_var_exists` / `tl_env_var_value` / `_tl_env_path_separator`
;; symbols therefore sees them as plain undefined externs (`.extern …`), with no
;; backend-emitted definition and no `getenv`/`strlen` shim calls.
(define (compiler-backend-env-runtime-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-env-runtime-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "\ntl_env_var_exists:\n"))
        (not (compiler-backend-string-contains? asm "\ntl_env_var_value:\n"))
        (compiler-backend-string-contains? asm "tl_alloc:\n")
        (not
          (compiler-backend-string-contains? asm "_tl_env_path_separator:\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-env-runtime-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-env-runtime-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "\ntl_env_var_exists:\n"))
        (not (compiler-backend-string-contains? asm "\ntl_env_var_value:\n"))
        (not (compiler-backend-string-contains? asm "    call getenv\n"))
        (not (compiler-backend-string-contains? asm "    call strlen\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-stdlib-env-runtime-source) : String
  "(module stdlib.env.test)
(unsafe (extern (env-ffi-getenv [arg0 : (Ptr u8)]) : (Ptr u8) (:symbol \"getenv\")))
(unsafe (extern (env-ffi-strlen [arg0 : (Ptr u8)]) : i64 (:symbol \"strlen\")))
(define (env-var-exists? [name : String]) : bool
  (let
    [_ : String name]
    (not (ptr-null? (unsafe (env-ffi-getenv (ptr-null : (Ptr u8))))))))
(define (env-var-value [name : String]) : String
  (let
    [_ : String name]
    (let
      [_ : i64 (unsafe (env-ffi-strlen (ptr-null : (Ptr u8))))]
      \"\")))
(define (env-path-separator) : String
  (cfg windows \";\" \":\"))
(define (main) : i64
  (let
    [name : String \"TYPELISP_TEST_ENV\"]
    (if (env-var-exists? name)
      (string-length (env-var-value name))
      (string-length (env-path-separator)))))")

(define (compiler-backend-stdlib-env-runtime-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-stdlib-env-runtime-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".extern getenv\n")
        (compiler-backend-string-contains? asm ".extern strlen\n")
        (not (compiler-backend-string-contains? asm "\ntl_env_var_exists:\n"))
        (not (compiler-backend-string-contains? asm "\ntl_env_var_value:\n"))
        (not
          (compiler-backend-string-contains? asm "_tl_env_path_separator:\n"))
        (not (compiler-backend-string-contains? asm "tl_env_path_separator:\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-stdlib-env-runtime-ok?) : bool
  (and
    (compiler-backend-stdlib-env-runtime-target-ok? (BackendTargetLinux))
    (compiler-backend-stdlib-env-runtime-target-ok? (BackendTargetWindows))))

(define (compiler-backend-append-file-status-ok?) : bool
  (match (compiler-backend-emit-source
    "(extern (append-file-status [arg0 : String] [arg1 : String]) : i64 (:symbol \"tl_append_file_status\"))
(define (main) : i64 (append-file-status \"out.txt\" \"x\"))")
    [(OkCompilerBackend asm)
      (and
        (not
          (compiler-backend-string-contains? asm ".L_tl_append_file_status:\n"))
        (compiler-backend-string-contains?
          asm
          "    call tl_append_file_status\n")
        (compiler-backend-string-contains?
          asm
          ".extern tl_append_file_status\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-no-public-runtime-symbol?
  [asm : String]
  [name : String]) : bool
  (and
    (not (compiler-backend-string-contains? asm (str-cat ".globl " name "\n")))
    (not (compiler-backend-string-contains? asm (str-cat "\n" name ":\n")))))

(define (compiler-backend-no-public-io-fs-runtime-symbols? [asm : String]) : bool
  (and
    (backend-and8
      (compiler-backend-no-public-runtime-symbol? asm "tl_read_file")
      (compiler-backend-no-public-runtime-symbol? asm "tl_write_file")
      (compiler-backend-no-public-runtime-symbol? asm "tl_file_exists")
      (compiler-backend-no-public-runtime-symbol? asm "tl_read_file_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_write_file_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_append_file_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_file_exists_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_file_open_status"))
    (backend-and8
      (compiler-backend-no-public-runtime-symbol? asm "tl_file_close_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_file_write_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_file_flush_status")
      (compiler-backend-no-public-runtime-symbol?
        asm
        "tl_file_read_chunk_status")
      (compiler-backend-no-public-runtime-symbol?
        asm
        "tl_file_read_chunk_bytes")
      (compiler-backend-no-public-runtime-symbol? asm "tl_file_read_chunk_eof")
      (compiler-backend-no-public-runtime-symbol? asm "tl_fs_mkdir_status")
      (compiler-backend-no-public-runtime-symbol?
        asm
        "tl_fs_remove_file_status"))
    (backend-and8
      (compiler-backend-no-public-runtime-symbol? asm "tl_fs_remove_dir_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_fs_rename_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_fs_process_id")
      (compiler-backend-no-public-runtime-symbol?
        asm
        "tl_fs_current_dir_status")
      (compiler-backend-no-public-runtime-symbol? asm "tl_fs_current_dir")
      (compiler-backend-no-public-runtime-symbol? asm "tl_read_stdin_line")
      (compiler-backend-no-public-runtime-symbol? asm "tl_read_stdin_bytes")
      (compiler-backend-no-public-runtime-symbol? asm "tl_stdin_eof"))
    (compiler-backend-no-public-runtime-symbol? asm "tl_flush_stdout")))

(define (compiler-backend-private-io-fs-runtime-source) : String
  "(extern (runtime-read-file [arg0 : (Ptr u8)] [arg1 : i64]) : String (:symbol \".L_tl_read_file\"))
(extern (runtime-write-file [arg0 : (Ptr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : i64]) : unit (:symbol \".L_tl_write_file\"))
(extern (runtime-file-exists? [arg0 : (Ptr u8)] [arg1 : i64]) : bool (:symbol \".L_tl_file_exists\"))
(extern (runtime-read-file-status [arg0 : (Ptr u8)] [arg1 : i64]) : i64 (:symbol \".L_tl_read_file_status\"))
(extern (runtime-write-file-status [arg0 : (Ptr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : i64]) : i64 (:symbol \".L_tl_write_file_status\"))
(extern (runtime-append-file-status [arg0 : (Ptr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : i64]) : i64 (:symbol \".L_tl_append_file_status\"))
(extern (runtime-file-exists-status [arg0 : (Ptr u8)] [arg1 : i64]) : i64 (:symbol \".L_tl_file_exists_status\"))
(extern (runtime-file-open-status [arg0 : (Ptr u8)] [arg1 : i64] [arg2 : i64]) : i64 (:symbol \".L_tl_file_open_status\"))
(extern (runtime-file-close-status [arg0 : i64]) : i64 (:symbol \".L_tl_file_close_status\"))
(extern (runtime-file-write-status [arg0 : i64] [arg1 : (Ptr u8)] [arg2 : i64]) : i64 (:symbol \".L_tl_file_write_status\"))
(extern (runtime-file-flush-status [arg0 : i64]) : i64 (:symbol \".L_tl_file_flush_status\"))
(extern (runtime-file-read-chunk-status [arg0 : i64] [arg1 : i64]) : i64 (:symbol \".L_tl_file_read_chunk_status\"))
(extern (runtime-file-read-chunk-bytes [arg0 : i64]) : String (:symbol \".L_tl_file_read_chunk_bytes\"))
(extern (runtime-file-read-chunk-eof [arg0 : i64]) : bool (:symbol \".L_tl_file_read_chunk_eof\"))
(extern (runtime-fs-mkdir-status [arg0 : (Ptr u8)] [arg1 : i64]) : i64 (:symbol \".L_tl_fs_mkdir_status\"))
(extern (runtime-fs-remove-file-status [arg0 : (Ptr u8)] [arg1 : i64]) : i64 (:symbol \".L_tl_fs_remove_file_status\"))
(extern (runtime-fs-remove-dir-status [arg0 : (Ptr u8)] [arg1 : i64]) : i64 (:symbol \".L_tl_fs_remove_dir_status\"))
(extern (runtime-fs-rename-status [arg0 : (Ptr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : i64]) : i64 (:symbol \".L_tl_fs_rename_status\"))
(extern (runtime-fs-process-id) : i64 (:symbol \".L_tl_fs_process_id\"))
(extern (runtime-read-stdin-line) : String (:symbol \".L_tl_read_stdin_line\"))
(extern (runtime-read-stdin-bytes [arg0 : i64]) : String (:symbol \".L_tl_read_stdin_bytes\"))
(extern (runtime-stdin-eof) : bool (:symbol \".L_tl_stdin_eof\"))
(extern (runtime-flush-stdout) : unit (:symbol \".L_tl_flush_stdout\"))
(define (main) : i64
  (let
    [path : String \"target/private-runtime.txt\"]
    [data : String \"x\"]
    (begin
      (runtime-read-file (unsafe (string-data path)) (string-length path))
      (runtime-write-file
        (unsafe (string-data path))
        (string-length path)
        (unsafe (string-data data))
        (string-length data))
      (runtime-file-exists? (unsafe (string-data path)) (string-length path))
      (runtime-read-file-status
        (unsafe (string-data path))
        (string-length path))
      (runtime-write-file-status
        (unsafe (string-data path))
        (string-length path)
        (unsafe (string-data data))
        (string-length data))
      (runtime-append-file-status
        (unsafe (string-data path))
        (string-length path)
        (unsafe (string-data data))
        (string-length data))
      (runtime-file-exists-status
        (unsafe (string-data path))
        (string-length path))
      (runtime-file-open-status
        (unsafe (string-data path))
        (string-length path)
        0)
      (runtime-file-close-status 1)
      (runtime-file-write-status
        1
        (unsafe (string-data data))
        (string-length data))
      (runtime-file-flush-status 1)
      (runtime-file-read-chunk-status 1 8)
      (runtime-file-read-chunk-bytes 1)
      (runtime-file-read-chunk-eof 1)
      (runtime-fs-mkdir-status
        (unsafe (string-data path))
        (string-length path))
      (runtime-fs-remove-file-status
        (unsafe (string-data path))
        (string-length path))
      (runtime-fs-remove-dir-status
        (unsafe (string-data path))
        (string-length path))
      (runtime-fs-rename-status
        (unsafe (string-data path))
        (string-length path)
        (unsafe (string-data data))
        (string-length data))
      (runtime-fs-process-id)
      (runtime-read-stdin-line)
      (runtime-read-stdin-bytes 1)
      (runtime-stdin-eof)
      (runtime-flush-stdout)
      0)))")

(define (compiler-backend-private-io-fs-runtime-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-private-io-fs-runtime-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".extern _u2eL_tl_read_file\n")
          (compiler-backend-string-contains?
            asm
            ".extern _u2eL_tl_write_file\n")
          (compiler-backend-string-contains?
            asm
            ".extern _u2eL_tl_file_exists\n")
          (compiler-backend-string-contains?
            asm
            ".extern _u2eL_tl_file_open_status\n")
          (compiler-backend-string-contains?
            asm
            ".extern _u2eL_tl_fs_mkdir_status\n")
          (compiler-backend-string-contains?
            asm
            ".extern _u2eL_tl_fs_process_id\n")
          (compiler-backend-string-contains?
            asm
            ".extern _u2eL_tl_read_stdin_line\n")
          (compiler-backend-string-contains?
            asm
            ".extern _u2eL_tl_flush_stdout\n"))
        (backend-and8
          (not (compiler-backend-string-contains? asm ".L_tl_read_file:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_write_file:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_file_exists:\n"))
          (not
            (compiler-backend-string-contains? asm ".L_tl_file_open_status:\n"))
          (not
            (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_fs_process_id:\n"))
          (not
            (compiler-backend-string-contains? asm ".L_tl_read_stdin_line:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_flush_stdout:\n")))
        (compiler-backend-no-public-io-fs-runtime-symbols? asm))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-private-io-fs-runtime-labels-ok?) : bool
  (and
    (compiler-backend-private-io-fs-runtime-target-ok? (BackendTargetLinux))
    (compiler-backend-private-io-fs-runtime-target-ok? (BackendTargetWindows))))

(define (compiler-backend-public-fs-externs? [asm : String]) : bool
  (and
    (backend-and4
      (compiler-backend-string-contains? asm ".extern tl_fs_process_id\n")
      (compiler-backend-string-contains? asm ".extern tl_fs_mkdir_status\n")
      (compiler-backend-string-contains?
        asm
        ".extern tl_fs_remove_file_status\n")
      (compiler-backend-string-contains?
        asm
        ".extern tl_fs_remove_dir_status\n"))
    (compiler-backend-string-contains? asm ".extern tl_fs_rename_status\n")))

(define (compiler-backend-no-private-fs-runtime? [asm : String]) : bool
  (and
    (backend-and8
      (not (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n"))
      (not
        (compiler-backend-string-contains? asm ".L_tl_fs_remove_file_status:\n"))
      (not
        (compiler-backend-string-contains? asm ".L_tl_fs_remove_dir_status:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_fs_rename_status:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_fs_process_id:\n"))
      (not (compiler-backend-string-contains? asm ".globl tl_fs_process_id\n"))
      (not
        (compiler-backend-string-contains? asm ".globl tl_fs_mkdir_status\n"))
      (not (compiler-backend-string-contains? asm "    call _mkdir\n")))
    (not
      (compiler-backend-string-contains? asm "    call GetCurrentProcessId\n"))
    (not (compiler-backend-string-contains? asm ".L_tl_fs_read_dir_status:\n"))
    (not (compiler-backend-string-contains? asm ".L_tl_fs_read_dir:\n"))
    (backend-and4
      (not
        (compiler-backend-string-contains? asm ".L_tl_fs_file_kind_status:\n"))
      (not
        (compiler-backend-string-contains? asm ".L_tl_fs_file_size_status:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_fs_file_size:\n"))
      true)))

(define (compiler-backend-fs-runtime-source) : String
  "(extern (fs-process-id) : i64 (:symbol \"tl_fs_process_id\"))
(extern (fs-mkdir-status [arg0 : String]) : i64 (:symbol \"tl_fs_mkdir_status\"))
(extern (fs-remove-file-status [arg0 : String]) : i64 (:symbol \"tl_fs_remove_file_status\"))
(extern (fs-remove-dir-status [arg0 : String]) : i64 (:symbol \"tl_fs_remove_dir_status\"))
(extern (fs-rename-status [arg0 : String] [arg1 : String]) : i64 (:symbol \"tl_fs_rename_status\"))
(define (main) : i64
  (let
    [dir : String \"target/typelisp-fs\"]
    [artifact : String \"target/typelisp-fs/artifact.o\"]
    [from : String \"target/typelisp-fs/from name\"]
    [to : String \"target/typelisp-fs/to name\"]
    (+ (fs-process-id)
      (+ (fs-mkdir-status dir)
        (+ (fs-remove-file-status artifact)
          (+ (fs-remove-dir-status dir)
            (fs-rename-status from to)))))))")

(define (compiler-backend-fs-runtime-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-fs-runtime-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-public-fs-externs? asm)
        (compiler-backend-no-private-fs-runtime? asm))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-fs-runtime-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-fs-runtime-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-public-fs-externs? asm)
        (compiler-backend-no-private-fs-runtime? asm))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-fs-read-dir-runtime-removed-ok?) : bool
  (and
    (not (compiler-backend-runtime-helper-known? ".L_tl_fs_read_dir_status"))
    (not (compiler-backend-runtime-helper-known? ".L_tl_fs_read_dir"))))

(define (compiler-backend-fs-metadata-runtime-removed-ok?) : bool
  (backend-and4
    (not (compiler-backend-runtime-helper-known? ".L_tl_fs_file_kind_status"))
    (not (compiler-backend-runtime-helper-known? ".L_tl_fs_file_size_status"))
    (not (compiler-backend-runtime-helper-known? ".L_tl_fs_file_size"))
    true))

(define (compiler-backend-windows-private-fs-no-crt? [asm : String]) : bool
  (and
    (backend-and4
      (not (compiler-backend-string-contains? asm "_findfirst32"))
      (not (compiler-backend-string-contains? asm "_findnext32"))
      (not (compiler-backend-string-contains? asm "_findclose"))
      (not (compiler-backend-string-contains? asm "_stat64")))
    (not (compiler-backend-string-contains? asm "    .extern _errno\n"))
    (not (compiler-backend-string-contains? asm "    call _errno\n"))))

(define (compiler-backend-fs-current-dir-source) : String
  "(extern (tl_fs_current_dir_status) : i64)
(extern (tl_fs_current_dir) : String)
(define (fs-current-dir-status) : i64
  (tl_fs_current_dir_status))
(define (fs-current-dir) : String
  (tl_fs_current_dir))
(define (main) : i64
  (+ (fs-current-dir-status) (string-length (fs-current-dir))))")

(define (compiler-backend-fs-current-dir-extern-source) : String
  "(extern (tl_fs_current_dir_status) : i64)
(extern (tl_fs_current_dir) : String)
(define (main) : i64
  (+ (tl_fs_current_dir_status) (string-length (tl_fs_current_dir))))")

(define (compiler-backend-fs-current-dir-extern-only-source-ok?
  [source : String]) : bool
  (match (compiler-backend-emit-source source)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          ".extern tl_fs_current_dir_status\n")
        (compiler-backend-string-contains? asm ".extern tl_fs_current_dir\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_fs_current_dir_status\n")
        (backend-and4
          (compiler-backend-no-public-runtime-symbol?
            asm
            "tl_fs_current_dir_status")
          (compiler-backend-no-public-runtime-symbol? asm "tl_fs_current_dir")
          (not (compiler-backend-string-contains? asm "getcwd:\n"))
          (not
            (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-fs-current-dir-extern-only-ok?) : bool
  (and
    (compiler-backend-fs-current-dir-extern-only-source-ok?
      (compiler-backend-fs-current-dir-source))
    (compiler-backend-fs-current-dir-extern-only-source-ok?
      (compiler-backend-fs-current-dir-extern-source))))

(define (compiler-backend-windows-fs-current-dir-extern-only-source-ok?
  [source : String]) : bool
  (match (compiler-backend-emit-source-for-target source (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          ".extern tl_fs_current_dir_status\n")
        (compiler-backend-string-contains? asm ".extern tl_fs_current_dir\n")
        (compiler-backend-no-public-runtime-symbol?
          asm
          "tl_fs_current_dir_status")
        (backend-and4
          (compiler-backend-no-public-runtime-symbol? asm "tl_fs_current_dir")
          (not (compiler-backend-string-contains? asm "    movq $38, %rax\n"))
          (not (compiler-backend-string-contains? asm "    syscall"))
          (not
            (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-fs-current-dir-extern-only-ok?) : bool
  (and
    (compiler-backend-windows-fs-current-dir-extern-only-source-ok?
      (compiler-backend-fs-current-dir-source))
    (compiler-backend-windows-fs-current-dir-extern-only-source-ok?
      (compiler-backend-fs-current-dir-extern-source))))

;; A refutable literal payload match (#651) lowers to a payload comparison that
;; branches to the next arm; confirm the resulting CFG reaches valid assembly.
(define (compiler-backend-literal-payload-source) : String
  "(defenum Maybe (None) (Some i64))
(define (classify [m : Maybe]) : i64
  (match m
    [(Some 0) 100]
    [(Some n) n]
    [None 5]))
(define (main) : i64 (classify (Some 0)))")

;; Confirm the refutable literal payload (#651) reaches valid assembly: the
;; function compiles and emits a `payload_ok` block (the in-bounds branch of the
;; payload comparison). `compiler-backend-asm-ok?` is smoke-source specific, so
;; check source-specific markers instead.
(define (compiler-backend-literal-payload-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-literal-payload-source))
    [(OkCompilerBackend asm)
      (and
        (or
          (compiler-backend-string-contains? asm "_tl_classify")
          (compiler-backend-string-contains? asm "_tl_f"))
        (compiler-backend-string-contains? asm "_payload_ok"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-f64-source) : String
  "(define (addf [a : f64] [b : f64]) : f64
  (+ a b))
(define (subf [a : f64] [b : f64]) : f64
  (- a b))
(define (ltf [a : f64] [b : f64]) : bool
  (< a b))
(define (main) : i64
  (if (ltf (subf (addf 1.5 2.5) 1.0) 4.5) 7 9))")

(define (compiler-backend-f64-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-f64-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    .double 1.5\n")
        (compiler-backend-string-contains? asm "    movsd %xmm0, ")
        (compiler-backend-string-contains? asm "    movsd %xmm1, ")
        (compiler-backend-string-contains? asm "    addsd %xmm1, %xmm0\n")
        (compiler-backend-string-contains? asm "    subsd %xmm1, %xmm0\n")
        (compiler-backend-string-contains? asm "    ucomisd %xmm1, %xmm0\n")
        (compiler-backend-string-contains? asm "    setb %al\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-f64-neg-source) : String
  "(define (negf [x : f64]) : f64
  (neg x))
(define (main) : i64
  (if (< (negf 1.5) 0.0) 0 1))")

(define (compiler-backend-f64-neg-object-source) : String
  "(define (negf [x : f64]) : f64
  (neg x))
(define (main) : i64 0)")

(define (compiler-backend-f64-neg-sign-mask-asm-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-f64-neg-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains?
            asm
            "    xorpd .L_tl_f64_sign_bit(%rip), %xmm0\n")
          (= (compiler-backend-string-count asm ".L_tl_f64_sign_bit:\n") 1)
          (compiler-backend-string-contains? asm "    .balign 16\n")
          (compiler-backend-string-contains?
            asm
            "    .quad 0x8000000000000000\n")
          (compiler-backend-string-contains? asm "    .quad 0\n")
          (not
            (compiler-backend-string-contains?
              asm
              "    movabsq $0x8000000000000000, %rax\n"))
          (not (compiler-backend-string-contains? asm "    movq %rax, %xmm1\n"))
          true)
        (not (compiler-backend-string-contains? asm "    xorpd %xmm1, %xmm0\n"))
        (match (compiler-backend-emit-source (compiler-backend-f64-source))
          [(OkCompilerBackend no-neg-asm)
            (not
              (compiler-backend-string-contains?
                no-neg-asm
                ".L_tl_f64_sign_bit"))]
          [(ErrCompilerBackend _) false]))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-f64-neg-sign-mask-object-render-ok?
  [image : CompilerObjectImage]
  [target : CompilerBackendTarget]) : bool
  (match target
    [(BackendTargetLinux)
      (match (compiler-object-elf-render image)
        [(OkCompilerObjectElf _) true]
        [(ErrCompilerObjectElf _) false])]
    [(BackendTargetWindows)
      (match (compiler-object-coff-render image)
        [(OkCompilerObjectCoff _) true]
        [(ErrCompilerObjectCoff _) false])]))

(define (compiler-backend-f64-neg-sign-mask-object-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-object-image-for-target
    (compiler-backend-f64-neg-object-source)
    target)
    [(OkCompilerBackendObject image)
      (let
        [sections : CompilerObjectSectionList (struct-get image sections)]
        [symbols : CompilerObjectSymbolList (struct-get image symbols)]
        [relocs : CompilerObjectRelocationList (struct-get image relocations)]
        [label : String (compiler-backend-f64-sign-bit-label)]
        (and
          (backend-and8
            (compiler-object-symbol-list-contains?
              symbols
              label
              (ObjectSymbolLocal)
              (ObjectSymbolData))
            (compiler-object-section-contains-label?
              sections
              (ObjectSectionRodata)
              label)
            (compiler-object-section-contains-align?
              sections
              (ObjectSectionRodata)
              16)
            (compiler-object-section-label-has-i64-pair?
              sections
              (ObjectSectionRodata)
              label
              -9223372036854775808
              0)
            (compiler-object-section-contains-xorpd-rip? sections label)
            (compiler-object-relocation-list-contains?
              relocs
              (ObjectRelocRipValue)
              label)
            true
            true)
          (compiler-backend-f64-neg-sign-mask-object-render-ok? image target)))]
    [(ErrCompilerBackendObject _) false]))

(define (compiler-backend-f64-neg-sign-mask-object-ok?) : bool
  (and
    (compiler-backend-f64-neg-sign-mask-object-target-ok? (BackendTargetLinux))
    (compiler-backend-f64-neg-sign-mask-object-target-ok?
      (BackendTargetWindows))))

(define (compiler-backend-f64-neg-sign-mask-ok?) : bool
  (and
    (compiler-backend-f64-neg-sign-mask-asm-ok?)
    (compiler-backend-f64-neg-sign-mask-object-ok?)))

(define (compiler-backend-f32-literal-binop-source) : String
  "(define (main) : i64
  (let
    [b : f32 12.0]
    [x : i64 (if (< 11.0 b) 1 0)]
    [y : i64 (if (< b 13.0) 2 0)]
    [z : i64 (if (< (+ 1.0 b) 13.5) 4 0)]
    (+ x (+ y z))))")

(define (compiler-backend-f32-literal-binop-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-f32-literal-binop-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    ucomiss %xmm1, %xmm0\n")
        (compiler-backend-string-contains? asm "    addss %xmm1, %xmm0\n")
        (compiler-backend-string-contains? asm "    cvtsd2ss %xmm0, %xmm0\n")
        (not (compiler-backend-string-contains? asm "    ucomisd")))]
    [(ErrCompilerBackend _) false]))

;; Backend-owned replacement for the Rust bool logic codegen checks (#1044):
;; `and`/`or` arrive from the lowerer as branches, not eager bytewise ops, and
;; bool equality still uses the comparison/setcc path.
(define (compiler-backend-bool-and-source) : String
  "(defmacro (and [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool true)
    `(if ,(expr-list-head args)
       (and ,@(expr-list-tail args))
       false)))
(define (f [a : bool] [b : bool]) : bool (and a b))")

(define (compiler-backend-bool-or-source) : String
  "(defmacro (or [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool false)
    `(if ,(expr-list-head args)
       true
       (or ,@(expr-list-tail args)))))
(define (f [a : bool] [b : bool]) : bool (or a b))")

(define (compiler-backend-bool-eq-source) : String
  "(define (f [a : bool] [b : bool]) : bool (= a b))")

(define (compiler-backend-bool-not-source) : String
  "(define (f [a : bool]) : bool (not a))")

(define (compiler-backend-direct-condition-branch-ok?) : bool
  (match (compiler-backend-emit-branch
    (compiler-reg-assignment-cons
      (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
      CompilerRegAssignmentNil)
    "bool_branch"
    (IrValueVar 0)
    "yes"
    "no"
    (CompilerBackendNoLabel))
    [(OkCompilerBackend reg-asm)
      (match (compiler-backend-emit-branch
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 0 (CompilerRegSpill -24))
          CompilerRegAssignmentNil)
        "bool_branch"
        (IrValueVar 0)
        "yes"
        "no"
        (CompilerBackendNoLabel))
        [(OkCompilerBackend spill-asm)
          (and
            (compiler-backend-string-contains? reg-asm "    testq %r12, %r12\n")
            (not
              (compiler-backend-string-contains?
                reg-asm
                "    movq %r12, %rax\n"))
            (compiler-backend-string-contains?
              spill-asm
              "    cmpq $0, -24(%rbp)\n")
            (not
              (compiler-backend-string-contains?
                spill-asm
                "    movq -24(%rbp), %rax\n")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-todo-marker) : String
  (string-append "# " "TODO"))

(define (compiler-backend-bool-control-flow-ok?) : bool
  (and
    (backend-and8
      (compiler-backend-source-contains?
        (compiler-backend-bool-and-source)
        "    je ")
      (compiler-backend-source-not-contains?
        (compiler-backend-bool-and-source)
        "    andb ")
      (compiler-backend-source-contains?
        (compiler-backend-bool-or-source)
        "    je ")
      (compiler-backend-source-not-contains?
        (compiler-backend-bool-or-source)
        "    orb ")
      (compiler-backend-source-contains?
        (compiler-backend-bool-eq-source)
        "    sete %al\n")
      (compiler-backend-source-not-contains?
        (compiler-backend-bool-and-source)
        (compiler-backend-todo-marker))
      (compiler-backend-source-not-contains?
        (compiler-backend-bool-or-source)
        (compiler-backend-todo-marker))
      (compiler-backend-source-not-contains?
        (compiler-backend-bool-eq-source)
        (compiler-backend-todo-marker)))
    (backend-and4
      (compiler-backend-source-contains?
        (compiler-backend-bool-not-source)
        "    xorq $1, %rax\n")
      (compiler-backend-source-not-contains?
        (compiler-backend-bool-not-source)
        "    testq %rax, %rax\n    sete %al\n    movzbl %al, %eax\n")
      (compiler-backend-source-not-contains?
        (compiler-backend-bool-not-source)
        (compiler-backend-todo-marker))
      (compiler-backend-direct-condition-branch-ok?))))

;; Backend-owned scalar instruction emit-shape coverage for stable wide integer
;; forms (#1353).
(define (compiler-backend-scalar-wide-source) : String
  "(define (xor64 [a : i64] [b : i64]) : i64 (bit-xor a b))
(define (shl64 [a : i64] [b : i64]) : i64 (shl a b))
(define (shr64 [a : i64] [b : i64]) : i64 (shr a b))")

(define (compiler-backend-scalar-wide-ops-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-scalar-wide-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (or
          (compiler-backend-string-contains? asm "    xorq %r8, %rax\n")
          (compiler-backend-string-contains? asm "    xorq %rcx, %rax\n"))
        (compiler-backend-string-contains? asm "    shlq %cl, %rax\n")
        (compiler-backend-string-contains? asm "    sarq %cl, %rax\n")
        (not (compiler-backend-string-contains? asm "    orq "))
        (not (compiler-backend-string-contains? asm "    addq %r8, %rax\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker)))
        true
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-i64-immediate-load-shape-ok?) : bool
  (backend-and8
    (string-eq
      (compiler-backend-emit-load-i64-immediate 0 "%rax")
      "    xorl %eax, %eax\n")
    (string-eq
      (compiler-backend-emit-load-i64-immediate 1 "%rax")
      "    movl $1, %eax\n")
    (string-eq
      (compiler-backend-emit-load-i64-immediate 2147483647 "%r11")
      "    movl $2147483647, %r11d\n")
    (string-eq
      (compiler-backend-emit-load-i64-immediate -1 "%rax")
      "    movq $-1, %rax\n")
    (string-eq
      (compiler-backend-emit-load-i64-immediate 2147483648 "%rax")
      "    movq $2147483648, %rax\n")
    true
    true
    true))

(define (compiler-backend-scalar-div-mod-source) : String
  "(define (div64 [a : i64] [b : i64]) : i64 (/ a b))
(define (mod64 [a : i64] [b : i64]) : i64 (% a b))
(define (main) : i64
  (+ (div64 42 6) (mod64 22 7)))")

(define (compiler-backend-scalar-div-mod-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-scalar-div-mod-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains?
          asm
          "    testq %r8, %r8\n    jne 1f\n    call tl_div_abort\n1:\n")
        (compiler-backend-string-contains?
          asm
          "    cmpq %r10, %rax\n    jne 1f\n")
        (compiler-backend-string-contains?
          asm
          "    cmpq %r11, %r8\n    jne 1f\n    call tl_div_abort\n1:\n")
        (compiler-backend-string-contains? asm "    cqto\n")
        (compiler-backend-string-contains? asm "    idivq %r8\n")
        (compiler-backend-string-contains? asm "    movq %rdx, %rax\n")
        (not (compiler-backend-string-contains? asm ".globl tl_div_abort\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-constant-divisor-strength-source) : String
  "(define (sdiv3 [a : i64]) : i64 (/ a 3))
(define (smod-prime [a : i64]) : i64 (% a 1000000007))
(define (udiv3 [a : u64]) : u64 (/ a (cast 3 : u64)))
(define (umod8 [a : u64]) : u64 (% a (cast 8 : u64)))
(define (udiv-high [a : u64]) : u64 (/ a (cast -2 : u64)))
(define (main) : i64
  (+ (sdiv3 -10)
    (+ (smod-prime -10)
      (+ (cast (udiv3 (cast 42 : u64)) : i64)
        (+ (cast (umod8 (cast 42 : u64)) : i64)
          (cast (udiv-high (cast -1 : u64)) : i64))))))")

(define (compiler-backend-constant-divisor-strength-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-constant-divisor-strength-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains?
          asm
          "    movabsq $6148914691236517206, %r8\n    imulq %r8\n")
        (compiler-backend-string-contains?
          asm
          "    movabsq $-8543223828751151131, %r8\n    imulq %r8\n")
        (compiler-backend-string-contains?
          asm
          "    movabsq $-6148914691236517205, %r8\n    mulq %r8\n")
        (compiler-backend-string-contains?
          asm
          "    movabsq $7, %r8\n    andq %r8, %rax\n")
        (not (compiler-backend-string-contains? asm "    idivq %r8\n"))
        (not (compiler-backend-string-contains? asm "    divq %r8\n"))
        (not (compiler-backend-string-contains? asm "    call tl_div_abort\n"))
        (and
          (not (compiler-backend-string-contains? asm ".extern tl_div_abort\n"))
          (not (compiler-backend-string-contains? asm ".globl tl_div_abort\n"))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-divrem-binop-types [ty : AstType]) : CompilerRegVarTypeList
  (compiler-reg-var-type-cons
    (CompilerRegVarType 0 ty)
    (compiler-reg-var-type-cons
      (CompilerRegVarType 1 ty)
      (compiler-reg-var-type-cons
        (CompilerRegVarType 2 ty)
        CompilerRegVarTypeNil))))

(define (compiler-backend-divrem-binop-asm
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (compiler-backend-emit-binop
    (compiler-backend-divrem-binop-types ty)
    (CompilerBackendGlobalTypeNil)
    CompilerRegAssignmentNil
    2
    op
    (IrValueVar 0)
    rhs
    ty))

(define (compiler-backend-divrem-binop-guard-shape?
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [want-guard? : bool]
  [want-remainder? : bool]) : bool
  (match (compiler-backend-divrem-binop-asm op rhs ty)
    [(OkCompilerBackend asm)
      (and
        (if want-guard?
          (compiler-backend-string-contains? asm "    call tl_div_abort\n")
          (not
            (compiler-backend-string-contains? asm "    call tl_div_abort\n")))
        (compiler-backend-string-contains? asm "    idivq %r8\n")
        (if want-remainder?
          (compiler-backend-string-contains? asm "    movq %rdx, %rax\n")
          true)
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-safe-divrem-guard-elision-ok?) : bool
  (and
    (backend-and4
      (compiler-backend-divrem-binop-guard-shape?
        (IrBinDiv)
        (IrValueVar 1)
        (AstTyI64)
        true
        false)
      (compiler-backend-divrem-binop-guard-shape?
        (IrBinSafeDiv)
        (IrValueVar 1)
        (AstTyI64)
        false
        false)
      (compiler-backend-divrem-binop-guard-shape?
        (IrBinSafeMod)
        (IrValueVar 1)
        (AstTyI64)
        false
        true)
      (compiler-backend-divrem-binop-guard-shape?
        (IrBinSafeDiv)
        (IrValueI64 (- 0 1))
        (AstTyI64)
        false
        false))
    (not
      (compiler-backend-binop-needs-div-abort?
        (IrBinSafeDiv)
        (IrValueVar 1)
        (AstTyI64)))))

(define (compiler-backend-shift-guard-source) : String
  "(define (main) : i64 (shl 1 -1))")

(define (compiler-backend-shift-guard-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-shift-guard-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm "    movq $-1,")
        (compiler-backend-string-contains?
          asm
          "    testq %r8, %r8\n    jge 1f\n    call tl_shift_abort\n1:\n")
        (compiler-backend-string-contains?
          asm
          "    cmpq $64, %r8\n    jb 1f\n    call tl_shift_abort\n1:\n")
        (compiler-backend-string-contains? asm "    call tl_shift_abort\n")
        (not (compiler-backend-string-contains? asm ".globl tl_shift_abort\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_shift_msg:"))
        (not (compiler-backend-string-contains? asm "    shlq $-1, %rax\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-checked-trap-entry-block) : CompilerIrBlock
  (compiler-ir-block
    "entry"
    (compiler-ir-instr-cons
      (IrInstrBinOp 0 (IrBinEq) (IrValueI64 0) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "div_trap" "div_ok")
        IrInstrNil))))

(define (compiler-backend-checked-trap-div-block) : CompilerIrBlock
  (compiler-ir-block
    "div_trap"
    (compiler-ir-instr-cons
      (IrInstrCall 1 "tl_div_abort" (IrCallArgsNil) (AstTyUnit))
      (compiler-ir-instr-cons (IrInstrJump "div_ok") IrInstrNil))))

(define (compiler-backend-checked-trap-div-ok-block) : CompilerIrBlock
  (compiler-ir-block
    "div_ok"
    (compiler-ir-instr-cons
      (IrInstrBinOp 2 (IrBinDiv) (IrValueI64 42) (IrValueI64 6) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 3 (IrBinMod) (IrValueI64 22) (IrValueI64 7) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBinOp 4 (IrBinEq) (IrValueI64 64) (IrValueI64 64) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 4) "shift_trap" "shift_ok")
            IrInstrNil))))))

(define (compiler-backend-checked-trap-shift-block) : CompilerIrBlock
  (compiler-ir-block
    "shift_trap"
    (compiler-ir-instr-cons
      (IrInstrCall 5 "tl_shift_abort" (IrCallArgsNil) (AstTyUnit))
      (compiler-ir-instr-cons (IrInstrJump "shift_ok") IrInstrNil))))

(define (compiler-backend-checked-trap-shift-ok-block) : CompilerIrBlock
  (compiler-ir-block
    "shift_ok"
    (compiler-ir-instr-cons
      (IrInstrBinOp 6 (IrBinShl) (IrValueI64 1) (IrValueI64 2) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueVar 6)))
        IrInstrNil))))

(define (compiler-backend-checked-trap-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-backend-checked-trap-entry-block)
    (compiler-ir-block-cons
      (compiler-backend-checked-trap-div-block)
      (compiler-ir-block-cons
        (compiler-backend-checked-trap-div-ok-block)
        (compiler-ir-block-cons
          (compiler-backend-checked-trap-shift-block)
          (compiler-ir-block-cons
            (compiler-backend-checked-trap-shift-ok-block)
            IrBlockNil))))))

(define (compiler-backend-checked-trap-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        8
        (compiler-backend-checked-trap-blocks))
      IrFunctionNil)
    IrExternNil))

(define (compiler-backend-checked-trap-asm-shape-ok? [asm : String]) : bool
  (let
    [trap-branches : bool
      (backend-and4
        (compiler-backend-string-contains? asm ".Lf0_div_trap:\n")
        (compiler-backend-string-contains? asm ".Lf0_shift_trap:\n")
        (compiler-backend-string-contains? asm "    call tl_div_abort\n")
        (compiler-backend-string-contains? asm "    call tl_shift_abort\n"))]
    [helper-shapes : bool
      (backend-and8
        (not (compiler-backend-string-contains? asm ".globl tl_div_abort\n"))
        (not (compiler-backend-string-contains? asm "tl_div_abort:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_div_msg:"))
        (not (compiler-backend-string-contains? asm "movq $135, %rdi\n"))
        (not (compiler-backend-string-contains? asm ".globl tl_shift_abort\n"))
        (not (compiler-backend-string-contains? asm "tl_shift_abort:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_shift_msg:"))
        (not (compiler-backend-string-contains? asm "movq $129, %rdi\n")))]
    [op-shapes : bool
      (backend-and4
        (compiler-backend-string-contains? asm "    idivq %r8\n")
        (compiler-backend-string-contains? asm "    movq %rdx, %rax\n")
        (compiler-backend-string-contains? asm "    shlq $2, %rax\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [no-externs : bool
      (backend-and4
        (not (compiler-backend-string-contains? asm ".extern tl_div_abort\n"))
        (not (compiler-backend-string-contains? asm ".extern tl_shift_abort\n"))
        (not (compiler-backend-string-contains? asm "_tl_tl_div_abort"))
        (not (compiler-backend-string-contains? asm "_tl_tl_shift_abort")))]
    (and trap-branches helper-shapes op-shapes no-externs)))

(define (compiler-backend-checked-trap-emit-shape-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-checked-trap-program))
    [(OkCompilerBackend asm) (compiler-backend-checked-trap-asm-shape-ok? asm)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-narrow-binop-types
  [lhs-ty : AstType]
  [rhs-ty : AstType]) : CompilerRegVarTypeList
  (compiler-reg-var-type-cons
    (CompilerRegVarType 0 lhs-ty)
    (compiler-reg-var-type-cons
      (CompilerRegVarType 1 rhs-ty)
      CompilerRegVarTypeNil)))

(define (compiler-backend-narrow-binop-shape?
  [op : CompilerIrBinOp]
  [lhs-ty : AstType]
  [rhs-ty : AstType]
  [result-ty : AstType]
  [needle : String]
  [bad : String]) : bool
  (match (compiler-backend-emit-binop
    (compiler-backend-narrow-binop-types lhs-ty rhs-ty)
    (CompilerBackendGlobalTypeNil)
    CompilerRegAssignmentNil
    2
    op
    (IrValueVar 0)
    (IrValueVar 1)
    result-ty)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm needle)
        (if (string-eq bad "")
          true
          (not (compiler-backend-string-contains? asm bad)))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

;; Backend-owned narrow integer instruction selection coverage (#1393). These
;; checks pin the operand width and signedness-sensitive forms that source-level
;; execution tests do not distinguish.
(define (compiler-backend-narrow-scalar-instr-ok?) : bool
  (and
    (backend-and8
      (compiler-backend-narrow-binop-shape?
        (IrBinAdd)
        (AstTyI32)
        (AstTyI32)
        (AstTyI32)
        "    addl -16(%rbp), %eax\n"
        "    addq %r8, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinMul)
        (AstTyI32)
        (AstTyI32)
        (AstTyI32)
        "    imull -16(%rbp), %eax\n"
        "    imulq %r8, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinDiv)
        (AstTyI32)
        (AstTyI32)
        (AstTyI32)
        "    cdq\n    idivl %r8d\n"
        "    idivq %r8\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinAdd)
        (AstTyI8)
        (AstTyI8)
        (AstTyI8)
        "    addb -16(%rbp), %al\n"
        "    addq %r8, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinSub)
        (AstTyI8)
        (AstTyI8)
        (AstTyI8)
        "    subb -16(%rbp), %al\n"
        "    subq %r8, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinLt)
        (AstTyI8)
        (AstTyI8)
        (AstTyBool)
        "    cmpb -16(%rbp), %al\n    setl %al\n"
        "    cmpq %r8, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinMod)
        (AstTyI8)
        (AstTyI8)
        (AstTyI8)
        "    cbw\n    idivb %r8b\n    movb %ah, %al\n"
        "    idivq %r8\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinBitAnd)
        (AstTyI16)
        (AstTyI16)
        (AstTyI16)
        "    andw -16(%rbp), %ax\n"
        "    andq %r8, %rax\n"))
    (backend-and4
      (compiler-backend-narrow-binop-shape?
        (IrBinDiv)
        (AstTyI16)
        (AstTyI16)
        (AstTyI16)
        "    cwd\n    idivw %r8w\n"
        "    idivq %r8\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinMod)
        (AstTyU8)
        (AstTyU8)
        (AstTyU8)
        "    andw $0x00ff, %ax\n    divb %r8b\n    movb %ah, %al\n"
        "    idivq %r8\n")
      (and
        (compiler-backend-narrow-binop-shape?
          (IrBinShr)
          (AstTyI8)
          (AstTyU8)
          (AstTyI8)
          "    movq %r8, %rcx\n    sarb %cl, %al\n"
          "    sarq %cl, %rax\n")
        (compiler-backend-narrow-binop-shape?
          (IrBinShr)
          (AstTyU8)
          (AstTyU8)
          (AstTyU8)
          "    movq %r8, %rcx\n    shrb %cl, %al\n"
          "    sarb %cl, %al\n"))
      (and
        (compiler-backend-narrow-binop-shape?
          (IrBinShl)
          (AstTyU8)
          (AstTyU8)
          (AstTyU8)
          "    movq %r8, %rcx\n    shlb %cl, %al\n"
          "    shlq %cl, %rax\n")
        (compiler-backend-narrow-binop-shape?
          (IrBinLt)
          (AstTyU8)
          (AstTyU8)
          (AstTyBool)
          "    cmpb -16(%rbp), %al\n    setb %al\n"
          "    setl %al\n")))))

(define (compiler-backend-global-compare-types) : CompilerBackendGlobalTypeList
  (CompilerBackendGlobalTypeCons
    "g_next"
    (AstTyI64)
    (box
      (CompilerBackendGlobalTypeCons
        "g_cap"
        (AstTyI64)
        (box CompilerBackendGlobalTypeNil)))))

(define (compiler-backend-global-compare-binop-ok?) : bool
  (match (compiler-backend-emit-binop
    (CompilerRegVarTypeNil)
    (compiler-backend-global-compare-types)
    CompilerRegAssignmentNil
    0
    (IrBinGe)
    (IrValueGlobal "g_next")
    (IrValueGlobal "g_cap")
    (AstTyBool))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    cmpq %r8, %rax\n")
        (not (compiler-backend-string-contains? asm "    cmpb %r8b, %al\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-global-compare-program) : CompilerIrProgram
  (IrProgram
    (compiler-ir-global-cons
      (IrGlobal "g_next" (AstTyI64) (IrValueI64 1))
      (compiler-ir-global-cons
        (IrGlobal "g_cap" (AstTyI64) (IrValueI64 1024))
        IrGlobalNil))
    (compiler-ir-function-cons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        1
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrBinOp
                0
                (IrBinGe)
                (IrValueGlobal "g_next")
                (IrValueGlobal "g_cap")
                (AstTyBool))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 0) "full" "ok")
                IrInstrNil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              "full"
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueI64 1)))
                IrInstrNil))
            (compiler-ir-block-cons
              (compiler-ir-block
                "ok"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueI64 42)))
                  IrInstrNil))
              IrBlockNil))))
      IrFunctionNil)
    IrExternNil))

(define (compiler-backend-global-compare-branch-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-global-compare-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    cmpq %r8, %rax\n")
        (not (compiler-backend-string-contains? asm "    cmpb %r8b, %al\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-global-compare-width-ok?) : bool
  (and
    (compiler-backend-global-compare-binop-ok?)
    (compiler-backend-global-compare-branch-ok?)))

(define (compiler-backend-f64-abi-source) : String
  "(define (half [x : f64]) : f64 (/ x 2.0))
(define (callhalf [x : f64]) : f64 (half x))
(define (second [n : i64] [x : f64]) : f64 x)")

(define (compiler-backend-f64-abi-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-f64-abi-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm "    movq %rdi, -8(%rbp)\n")
        (compiler-backend-string-contains? asm "    movsd %xmm0, -16(%rbp)\n")
        (not
          (compiler-backend-string-contains? asm "    movsd %xmm1, -16(%rbp)\n"))
        (compiler-backend-string-contains? asm "    divsd %xmm1, %xmm0\n")
        (or
          (compiler-backend-call-or-jmp-ok? asm "_tl_half")
          (compiler-backend-call-or-jmp-ok? asm "_tl_callhalf")
          (compiler-backend-call-or-jmp-ok? asm "_tl_f"))
        (compiler-backend-string-contains? asm "    movsd %xmm0, ")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker)))
        true)]
    [(ErrCompilerBackend _) false]))

;; Windows f64 ABI emit-shape coverage (#1456): the first four positional
;; f64 args use xmm0..xmm3, the fifth is stacked after the 32-byte shadow
;; space, and f64 returns remain in xmm0.
(define (compiler-backend-win64-f64-abi-source) : String
  "(define (sum5
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]) : f64
  (+ (+ (+ (+ a b) c) d) e))

(define (call5 [x : f64]) : f64
  (+ 0.0 (sum5 x 2.0 3.0 4.0 5.0)))

(define (main) : i64
  (if (< (call5 1.0) 16.0) 42 0))")

(define (compiler-backend-win64-f64-abi-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-win64-f64-abi-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "    movsd %xmm0, -8(%rbp)\n")
          (compiler-backend-string-contains? asm "    movsd %xmm1, -16(%rbp)\n")
          (compiler-backend-string-contains? asm "    movsd %xmm2, -24(%rbp)\n")
          (compiler-backend-string-contains? asm "    movsd %xmm3, -32(%rbp)\n")
          (compiler-backend-string-contains? asm "    subq $96, %rsp\n")
          (compiler-backend-string-contains?
            asm
            "    movsd -48(%rbp), %xmm15\n")
          (compiler-backend-string-contains? asm "    movsd %xmm15, 32(%rsp)\n")
          (compiler-backend-string-contains? asm "    movsd 48(%rbp), %xmm0\n"))
        (or
          (compiler-backend-string-contains? asm "    call _tl_f")
          (compiler-backend-string-contains? asm "    call _tl_sum5")
          (compiler-backend-string-contains? asm "    call _tl_call5"))
        (compiler-backend-string-contains? asm "    movsd %xmm0, -16(%rbp)\n")
        (not (compiler-backend-string-contains? asm "too many call args"))
        (not (compiler-backend-string-contains? asm "    syscall"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-register-f64-aggregate-source) : String
  "(defstruct PairF64 (x f64) (y f64))
(defstruct MixIF (i i64) (f f64))
(define global-pair : PairF64 (PairF64 1.0 2.0))
(define (make-pair [x : f64] [y : f64]) : PairF64
  (PairF64 x y))
(define (sum-pair [p : PairF64]) : f64
  (+ (struct-get p x) (struct-get p y)))
(define (mixed [m : MixIF]) : f64
  (struct-get m f))
(define (main) : i64
  (begin
    (set! global-pair (make-pair 3.0 4.0))
    (if (= (+ (sum-pair global-pair) (mixed (MixIF 5 6.0))) 13.0)
      42
      0)))")

(define (compiler-backend-register-f64-aggregate-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-register-f64-aggregate-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "    movsd ")
          (compiler-backend-string-contains? asm "%xmm0")
          (compiler-backend-string-contains? asm "%xmm1")
          (compiler-backend-string-contains? asm "    call ")
          (not (compiler-backend-string-contains? asm "    movsd %rax"))
          (not (compiler-backend-string-contains? asm "    movsd %rdx"))
          (not (compiler-backend-string-contains? asm ", %rax\n    movsd"))
          (not (compiler-backend-string-contains? asm ", %rdx\n    movsd")))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-register-f64-aggregate-ok?) : bool
  (and
    (compiler-backend-register-f64-aggregate-target-ok? (BackendTargetLinux))
    (compiler-backend-register-f64-aggregate-target-ok? (BackendTargetWindows))))

(define (compiler-backend-register-f32-aggregate-source) : String
  "(defstruct Vec2F32 (x f32) (y f32))
(defstruct MixUF (tag u32) (value f32))
(define global-vec : Vec2F32 (Vec2F32 1.0 2.0))
(define (make-vec [x : f32] [y : f32]) : Vec2F32
  (Vec2F32 x y))
(define (sum-vec [v : Vec2F32]) : f32
  (+ (struct-get v x) (struct-get v y)))
(define (choose-vec [take-left : bool]) : Vec2F32
  (if take-left
    (Vec2F32 1.25 2.75)
    (Vec2F32 9.0 10.0)))
(define (mixed [m : MixUF]) : f32
  (struct-get m value))
(define (main) : i64
  (begin
    (set! global-vec (make-vec 3.5 4.5))
    (if (= (+ (sum-vec global-vec) (sum-vec (choose-vec true))) 12.0)
      (cast (mixed (MixUF (cast 5 : u32) 6.0)) : i64)
      0)))")

(define (compiler-backend-register-f32-aggregate-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-register-f32-aggregate-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "    movd %xmm0, %eax\n")
          (compiler-backend-string-contains? asm "    movd %eax, %xmm0\n")
          (compiler-backend-string-contains? asm "    movsd ")
          (compiler-backend-string-contains? asm "%xmm0")
          (compiler-backend-string-contains? asm "    call ")
          (compiler-backend-string-contains? asm "    movss 4(%r10), %xmm0\n")
          (not (compiler-backend-string-contains? asm "unsupported bitcast"))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker))))
        (not (compiler-backend-string-contains? asm "    movsd %rax"))
        (not (compiler-backend-string-contains? asm "    movsd %rdx")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-register-f32-aggregate-ok?) : bool
  (and
    (compiler-backend-register-f32-aggregate-target-ok? (BackendTargetLinux))
    (compiler-backend-register-f32-aggregate-target-ok? (BackendTargetWindows))))

;; #750: a SysV call with seven integer args no longer rejects as "too many
;; call args". Source-level numeric literals are lowered into locals before
;; call-arg emission, so the 7th and 8th args still exercise the variable
;; stack-store path while `add8` reads them back from 16(%rbp)/24(%rbp).
(define (compiler-backend-stack-add-call-ok? [asm : String]) : bool
  (or
    (compiler-backend-string-contains? asm "    call _tl_add8")
    (compiler-backend-string-contains? asm "    call _tl_f")))

(define (compiler-backend-stack-mix-call-ok? [asm : String]) : bool
  (or
    (compiler-backend-string-contains? asm "    call _tl_mix")
    (compiler-backend-string-contains? asm "    call _tl_f")))

(define (compiler-backend-stack-int-args-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-stack-int-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (compiler-backend-string-contains? asm "    subq $16, %rsp\n")
        (compiler-backend-string-contains? asm "    movq %r11, 0(%rsp)\n")
        (compiler-backend-string-contains? asm "    addq $16, %rsp\n")
        (compiler-backend-stack-add-call-ok? asm)
        (compiler-backend-string-contains? asm "    movq 16(%rbp), %rax\n")
        (compiler-backend-string-contains? asm "    movq 24(%rbp), %rax\n"))]
    [(ErrCompilerBackend _) false]))

;; #750: a SysV call with ten f64 args uses xmm0..xmm7 then spills two on the
;; stack through %xmm15; the callee reads them back via movsd from the incoming
;; stack slots.
(define (compiler-backend-stack-f64-args-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-stack-f64-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (compiler-backend-string-contains? asm "    subq $16, %rsp\n")
        (compiler-backend-string-contains? asm "    movsd %xmm15, 0(%rsp)\n")
        (compiler-backend-string-contains? asm "    movsd %xmm15, 8(%rsp)\n")
        (compiler-backend-string-contains? asm "    movsd 16(%rbp), %xmm0\n")
        (compiler-backend-string-contains? asm "    movsd 24(%rbp), %xmm0\n"))]
    [(ErrCompilerBackend _) false]))

;; #750: a mixed call spilling one int and one f64 keeps the integer and float
;; register banks independent and uses the right scratch register for each
;; spilled arg.
(define (compiler-backend-stack-mixed-args-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-stack-mixed-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (compiler-backend-string-contains? asm "    movq %r11, 0(%rsp)\n")
        (compiler-backend-string-contains? asm "    movsd %xmm15, 8(%rsp)\n")
        (compiler-backend-stack-mix-call-ok? asm))]
    [(ErrCompilerBackend _) false]))

;; #750: the Windows positional ABI still reserves 32-byte shadow space, stacks
;; args after the first four, and stores them after the shadow space.
(define (compiler-backend-stack-windows-args-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-stack-int-args-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (compiler-backend-string-contains? asm "    call _tl_add8\n")
        (compiler-backend-string-contains? asm "    movq %r11, 32(%rsp)\n")
        (compiler-backend-string-contains? asm "    movq %r11, 56(%rsp)\n")
        (compiler-backend-string-contains? asm "    movq 48(%rbp), %rax\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-i64-type-list8) : AstTypeList
  (ast-type-cons
    (AstTyI64)
    (ast-type-cons
      (AstTyI64)
      (ast-type-cons
        (AstTyI64)
        (ast-type-cons
          (AstTyI64)
          (ast-type-cons
            (AstTyI64)
            (ast-type-cons
              (AstTyI64)
              (ast-type-cons (AstTyI64) (ast-type-cons (AstTyI64) AstTypeNil)))))))))

(define (compiler-backend-i64-immediate-call-args8) : CompilerIrCallArgs
  (compiler-ir-call-args-from-list
    (compiler-ir-value-cons
      (IrValueI64 1)
      (compiler-ir-value-cons
        (IrValueI64 2)
        (compiler-ir-value-cons
          (IrValueI64 3)
          (compiler-ir-value-cons
            (IrValueI64 4)
            (compiler-ir-value-cons
              (IrValueI64 5)
              (compiler-ir-value-cons
                (IrValueI64 6)
                (compiler-ir-value-cons
                  (IrValueI64 7)
                  (compiler-ir-value-cons (IrValueI64 8) IrValueNil))))))))))

(define (compiler-backend-immediate-stack-call-args-ok?) : bool
  (match (compiler-backend-emit-call-args
    (BackendTargetLinux)
    CompilerRegAssignmentNil
    (compiler-backend-i64-immediate-call-args8)
    (compiler-backend-i64-type-list8)
    false
    0
    0
    0
    0
    0
    (compiler-diagnostic-at-start "" "")
    (compiler-backend-program-index-build IrFunctionNil IrExternNil)
    0)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movq $7, 0(%rsp)\n")
        (compiler-backend-string-contains? asm "    movq $8, 8(%rsp)\n")
        (not (compiler-backend-string-contains? asm "    movq %r11, 0(%rsp)\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-stack-args-ok?) : bool
  (and
    (compiler-backend-stack-int-args-ok?)
    (compiler-backend-stack-f64-args-ok?)
    (compiler-backend-stack-mixed-args-ok?)
    (compiler-backend-stack-windows-args-ok?)
    (compiler-backend-immediate-stack-call-args-ok?)))

(define (compiler-backend-direct-tail-call-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-direct-tail-call-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    jmp _tl_finish\n")
        (not (compiler-backend-string-contains? asm "    call _tl_finish\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-direct-tail-call-stack-slot
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    movq %r11, 72(%rbp)\n"
    "    movq %r11, 24(%rbp)\n"))

(define (compiler-backend-direct-tail-call-stack-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-direct-tail-call-stack-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    jmp _tl_finishstack\n")
        (not
          (compiler-backend-string-contains? asm "    call _tl_finishstack\n"))
        (not (compiler-backend-string-contains? asm "    pushq %r11\n"))
        (compiler-backend-string-contains?
          asm
          (compiler-backend-direct-tail-call-stack-slot target)))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-direct-tail-immediate-stack-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-direct-tail-call-args
    target
    CompilerRegAssignmentNil
    (compiler-backend-i64-immediate-call-args8)
    (compiler-backend-i64-type-list8)
    (compiler-diagnostic-at-start "" ""))
    [(OkCompilerBackend asm)
      (if (compiler-backend-target-windows? target)
        (and
          (compiler-backend-string-contains? asm "    movq $5, 48(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq $8, 72(%rbp)\n")
          (not (compiler-backend-string-contains? asm "    pushq %r11\n")))
        (and
          (compiler-backend-string-contains? asm "    movq $7, 16(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq $8, 24(%rbp)\n")
          (not (compiler-backend-string-contains? asm "    pushq %r11\n"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-direct-tail-call-mixed-slot
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    movsd %xmm15, 136(%rbp)\n"
    "    movsd %xmm15, 24(%rbp)\n"))

(define (compiler-backend-direct-tail-call-mixed-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-direct-tail-call-mixed-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    jmp _tl_finishmixed\n")
        (not
          (compiler-backend-string-contains? asm "    call _tl_finishmixed\n"))
        (not (compiler-backend-string-contains? asm "    subq $8, %rsp\n"))
        (compiler-backend-string-contains?
          asm
          (compiler-backend-direct-tail-call-mixed-slot target)))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-direct-tail-call-ok?) : bool
  (and
    (compiler-backend-direct-tail-call-target-ok? (BackendTargetLinux))
    (compiler-backend-direct-tail-call-target-ok? (BackendTargetWindows))
    (compiler-backend-direct-tail-call-stack-target-ok? (BackendTargetLinux))
    (compiler-backend-direct-tail-call-stack-target-ok? (BackendTargetWindows))
    (compiler-backend-direct-tail-immediate-stack-target-ok?
      (BackendTargetLinux))
    (compiler-backend-direct-tail-immediate-stack-target-ok?
      (BackendTargetWindows))
    (compiler-backend-direct-tail-call-mixed-target-ok? (BackendTargetLinux))
    (compiler-backend-direct-tail-call-mixed-target-ok? (BackendTargetWindows))))

(define (compiler-backend-indirect-tail-call-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-indirect-tail-call-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    jmp *(%r11)\n")
        (not (compiler-backend-string-contains? asm "    jmp *%rax\n"))
        (not (compiler-backend-string-contains? asm "    movq (%r11), %rax\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-indirect-tail-call-stack-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-indirect-tail-call-stack-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    call *(%r11)\n")
        (not (compiler-backend-string-contains? asm "    jmp *(%r11)\n"))
        (not (compiler-backend-string-contains? asm "    call *%rax\n"))
        (not (compiler-backend-string-contains? asm "    movq (%r11), %rax\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-indirect-tail-call-ok?) : bool
  (and
    (compiler-backend-indirect-tail-call-target-ok? (BackendTargetLinux))
    (compiler-backend-indirect-tail-call-target-ok? (BackendTargetWindows))
    (compiler-backend-indirect-tail-call-stack-target-ok? (BackendTargetLinux))
    (compiler-backend-indirect-tail-call-stack-target-ok?
      (BackendTargetWindows))))

(define (compiler-backend-export-symbol-source) : String
  "(define (exported [x : i64]) (:export-symbol \"tl_exported_value\") : i64
  (+ x 1))
(define (main) : i64
  (exported 41))")

(define (compiler-backend-export-symbol-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-export-symbol-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm ".globl tl_exported_value\n")
        (compiler-backend-string-contains? asm "tl_exported_value:\n")
        (compiler-backend-call-or-jmp-ok? asm "tl_exported_value")
        (not
          (compiler-backend-string-contains? asm ".extern tl_exported_value\n"))
        (not (compiler-backend-string-contains? asm ".globl _tl_exported\n"))
        (not (compiler-backend-string-contains? asm "_tl_exported:\n"))
        (compiler-backend-string-contains? asm "main:\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-export-symbol-fixed-fault-source) : String
  "(extern (tl_oob_abort) : never)
(define (tl-runtime-oob-abort) (:export-symbol \"tl_oob_abort\") : never
  (tl_oob_abort))
(define (main) : i64 0)")

(define (compiler-backend-export-symbol-fixed-fault-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-export-symbol-fixed-fault-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl tl_oob_abort\n")
        (compiler-backend-string-contains? asm "tl_oob_abort:\n")
        (not (compiler-backend-string-contains? asm ".extern tl_oob_abort\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-duplicate-export-symbol-source) : String
  "(define (a) (:export-symbol \"dup_export\") : i64 1)
(define (b) (:export-symbol \"dup_export\") : i64 2)
(define (main) : i64 (+ (a) (b)))")

(define (compiler-backend-export-symbol-function-collision-source) : String
  "(define (normal) : i64 1)
(define (other) (:export-symbol \"_tl_normal\") : i64 2)
(define (main) : i64 (+ (normal) (other)))")

(define (compiler-backend-export-symbol-global-collision-source) : String
  "(define normal : i64 1)
(define (other) (:export-symbol \"_tl_normal\") : i64 2)
(define (main) : i64 (+ normal (other)))")

(define (compiler-backend-export-symbol-runtime-collision-source) : String
  "(define (own-alloc) (:export-symbol \"tl_alloc\") : i64 1)
(define (main) : i64 (own-alloc))")

(define (compiler-backend-export-symbol-main-source) : String
  "(define (main) (:export-symbol \"tl_not_main\") : i64 0)")

(define (compiler-backend-export-symbol-invalid-source) : String
  "(define (bad) (:export-symbol \"bad symbol\") : i64 1)
(define (main) : i64 (bad))")

(define (compiler-backend-export-symbol-extern-collision-source) : String
  "(extern (imported) : i64 (:symbol \"dup_link\"))
(define (exported) (:export-symbol \"dup_link\") : i64 42)
(define (main) : i64 (imported))")

(define (compiler-backend-export-symbol-diagnostics-ok?) : bool
  (and
    (backend-and4
      (compiler-backend-error-ok?
        (compiler-backend-duplicate-export-symbol-source)
        "backend: duplicate emitted function symbol dup_export")
      (compiler-backend-error-ok?
        (compiler-backend-export-symbol-function-collision-source)
        "backend: duplicate emitted function symbol _tl_normal")
      (compiler-backend-error-ok?
        (compiler-backend-export-symbol-global-collision-source)
        "backend: duplicate emitted function symbol _tl_normal")
      (compiler-backend-error-ok?
        (compiler-backend-export-symbol-runtime-collision-source)
        "backend: exported function symbol collides with runtime symbol tl_alloc"))
    (backend-and4
      (compiler-backend-error-ok?
        (compiler-backend-export-symbol-main-source)
        "backend: main cannot use :export-symbol")
      (compiler-backend-error-ok?
        (compiler-backend-export-symbol-invalid-source)
        "backend: invalid exported function symbol bad symbol")
      (compiler-backend-error-ok?
        (compiler-backend-export-symbol-extern-collision-source)
        "backend: extern symbol collides with emitted symbol dup_link")
      true)))

(define (compiler-backend-export-symbol-tests-ok?) : bool
  (and
    (compiler-backend-export-symbol-ok?)
    (compiler-backend-export-symbol-fixed-fault-ok?)
    (compiler-backend-export-symbol-diagnostics-ok?)))

(define (compiler-backend-clean-module-symbol-collision-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "pkg/a.tl::helper"
        IrParamNil
        (AstTyI64)
        0
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 1)))
              IrInstrNil))
          IrBlockNil))
      (compiler-ir-function-cons
        (IrFunction
          "pkg_a.tl::helper"
          IrParamNil
          (AstTyI64)
          0
          (compiler-ir-block-cons
            (compiler-ir-block
              "entry"
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueI64 2)))
                IrInstrNil))
            IrBlockNil))
        IrFunctionNil))
    IrExternNil))

(define (compiler-backend-clean-module-symbol-collision-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-clean-module-symbol-collision-program))
    [(ErrCompilerBackend diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "backend: duplicate emitted function symbol _tl_pkg_a_helper")]
    [(OkCompilerBackend _) false]))

(define (compiler-backend-raw-pointer-fixture-shape-ok?) : bool
  (match (compiler-backend-raw-pointer-fixture-emit (BackendTargetLinux))
    [(OkCompilerBackend asm)
      (backend-and8
        (or
          (>= (compiler-backend-string-count asm ".globl _tl_f") 2)
          (and
            (compiler-backend-string-contains? asm ".globl _tl_write_i64")
            (compiler-backend-string-contains? asm ".globl _tl_read_i64")))
        (or
          (compiler-backend-string-contains? asm "_tl_write_i64")
          (compiler-backend-string-contains? asm "_tl_f"))
        (or
          (>= (compiler-backend-string-count asm "    call _tl_f") 2)
          (and
            (compiler-backend-string-contains? asm "    call _tl_write_i64")
            (compiler-backend-string-contains? asm "    call _tl_read_i64")))
        (compiler-backend-string-contains? asm "main:\n")
        (compiler-backend-string-contains? asm "    call tl_alloc\n")
        (compiler-backend-string-contains? asm "tl_alloc:")
        (compiler-backend-string-contains? asm "    movq (%r10), %rax\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

;; Backend emit-shape coverage for arena-owned boxes (#1443). `(box 42)`
;; allocates `size-of(i64)` = 8 bytes via `tl_alloc` and stores the boxed value
;; into that storage; `(box-get b)` loads the value back through the box pointer.
;; Boxes reuse the existing `tl_alloc` / pointer store/load paths (no new IR or
;; runtime), so this locks down that the allocation, store, and load shapes are
;; emitted with no `# TODO` placeholder.
(define (compiler-backend-box-source) : String
  "(define (main) : i64
  (let
    [b : (Box i64) (box 42)]
    (box-get b)))")

(define (compiler-backend-box-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-box-source))
    [(OkCompilerBackend asm)
      (backend-and4
        ;; (box 42): allocate size-of(i64)=8 bytes for the box storage,
        (compiler-backend-string-contains-alloc-size? asm 8)
        ;; store the boxed value (materialized in %rax) into the box pointer,
        (compiler-backend-string-contains? asm "    movq %rax, (%r10)\n")
        ;; (box-get b): load the boxed value back through the box pointer.
        (compiler-backend-string-contains? asm "    movq (%r10), %rax\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

;; Backend emit-shape coverage for local tuple construction/ref (#1414).
;; `(tuple true 42)` allocates the tuple payload, materializes/stores the bool
;; byte and i64 at their offsets, and `(tuple-ref t 1)` loads the i64 slot back.
(define (compiler-backend-tuple-source) : String
  "(define (main) : i64
  (let
    [t : (Tuple bool i64) (tuple true 42)]
    (tuple-ref t 1)))")

(define (compiler-backend-tuple-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-tuple-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains-alloc-size? asm 16)
          (compiler-backend-string-contains? asm "    movq $1,")
          (compiler-backend-string-contains? asm "    movb %al, (%r10)\n")
          (compiler-backend-string-contains? asm "    movq $42,")
          (compiler-backend-string-contains? asm "    movq %rax, 8(%r10)\n")
          (compiler-backend-string-contains? asm "    movq 8(%r10), %rax\n")
          true
          true)
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-inline-struct-ok?) : bool
  (match (compiler-backend-emit-source (compiler-lower-inline-struct-source))
    [(OkCompilerBackend asm)
      (backend-and4
        (= (compiler-backend-string-count asm "    call tl_alloc\n") 0)
        (compiler-backend-string-contains? asm "    leaq -")
        (compiler-backend-string-contains? asm "main:\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-inline-enum-ok?) : bool
  (match (compiler-backend-emit-source (compiler-lower-inline-enum-source))
    [(OkCompilerBackend asm)
      (backend-and4
        (= (compiler-backend-string-count asm "    call tl_alloc\n") 0)
        (compiler-backend-string-contains? asm "    leaq -")
        (compiler-backend-string-contains? asm ".Lf0_match_arm.")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-inline-boxed-recursive-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-lower-inline-boxed-recursive-source))
    [(OkCompilerBackend asm)
      (backend-and4
        (= (compiler-backend-alloc-call-count asm) 1)
        ;; (box Nil) heap-allocates a full inline ListI64 value: tag (8) plus
        ;; the largest variant payload Cons(i64, (Box ListI64)) = 16, so 24
        ;; bytes. With default-inline aggregates (#1867) the box holds the
        ;; inline value, not an 8-byte handle.
        (compiler-backend-string-contains-alloc-size? asm 24)
        (compiler-backend-string-contains? asm "    leaq -")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-inline-hot-loop-struct-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-lower-inline-hot-loop-struct-source))
    [(OkCompilerBackend asm)
      ;; #2386: the loop's 16-byte `Pair` is now a register-resident group (built
      ;; and read in registers), so the loop body neither heap-allocates nor needs
      ;; a stack-slot address for it.
      (backend-and4
        (= (compiler-backend-string-count asm "    call tl_alloc\n") 0)
        (compiler-backend-string-contains? asm "main:\n")
        true
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-inline-aggregate-call-source) : String
  "(defstruct Color (r u8) (g u8) (b u8) (a u8))
(defenum Swatch (Empty) (Paint Color))
(define (make-color) : Color
  (Color (cast 5 : u8) (cast 7 : u8) (cast 11 : u8) (cast 13 : u8)))
(define (id-color [c : Color]) : Color c)
(define (use-color [c : Color]) : i64
  (+
    (cast (struct-get c r) : i64)
    (+
      (cast (struct-get c g) : i64)
      (+ (cast (struct-get c b) : i64) (cast (struct-get c a) : i64)))))
(define (id-swatch [s : Swatch]) : Swatch s)
(define (score-swatch [s : Swatch]) : i64
  (match s
    [Empty 0]
    [(Paint c) (use-color c)]))
(define (main) : i64
  (let
    [c : Color (id-color (make-color))]
    [s : Swatch (id-swatch (Paint c))]
    (if (= (use-color c) 36)
      (if (= (score-swatch s) 36) 42 2)
      1)))")

(define (compiler-backend-inline-aggregate-call-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-inline-aggregate-call-source)
    target)
    [(OkCompilerBackend asm)
      (backend-and4
        (compiler-backend-string-contains? asm "main:\n")
        (>= (compiler-backend-string-count asm "    call ") 6)
        ;; #1867 sret ABI: aggregate args/returns pass by caller slot pointer
        ;; and inline construction is stack storage -- no arena allocation.
        (= (compiler-backend-alloc-call-count asm) 0)
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-inline-aggregate-call-ok?) : bool
  (and
    (compiler-backend-inline-aggregate-call-target-ok? (BackendTargetLinux))
    (compiler-backend-inline-aggregate-call-target-ok? (BackendTargetWindows))))

(define (compiler-backend-inline-aggregate-copy-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-inline-aggregates-for-target
    (compiler-lower-inline-aggregate-copy-source)
    target)
    [(OkCompilerBackend asm)
      ;; #2386: `Pair` is a 16-byte all-integer struct, so it is register-resident
      ;; -- `id-pair` is a register-pair passthrough that carries both words in
      ;; registers end-to-end. The function is still emitted, but it does NOT do
      ;; the old pointer-load / pointer-store byte-copy ("(%r11), %rax" then
      ;; "%rax, (%r10)") that a memory aggregate required.
      (backend-and4
        (compiler-backend-string-contains? asm "id_pair")
        (not (compiler-backend-string-contains? asm "(%r11), %rax"))
        (not (compiler-backend-string-contains? asm "%rax, (%r10)"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-inline-aggregate-copy-ok?) : bool
  (and
    (compiler-backend-inline-aggregate-copy-target-ok? (BackendTargetLinux))
    (compiler-backend-inline-aggregate-copy-target-ok? (BackendTargetWindows))))

(define (compiler-backend-inline-aggregate-storage-ok?) : bool
  (and
    (compiler-backend-inline-struct-ok?)
    (compiler-backend-inline-enum-ok?)
    (compiler-backend-inline-boxed-recursive-ok?)
    (compiler-backend-inline-aggregate-call-ok?)
    (compiler-backend-inline-aggregate-copy-ok?)
    (compiler-backend-inline-hot-loop-struct-ok?)))

(define (compiler-backend-test-mode-scalar? [mode : CompilerBackendMode]) : bool
  (match mode
    [(BackendModeScalar) true]
    [_ false]))

(define (compiler-backend-test-mode-avx2? [mode : CompilerBackendMode]) : bool
  (match mode
    [(BackendModeAvx2) true]
    [_ false]))

(define (compiler-backend-test-mode-avx512? [mode : CompilerBackendMode]) : bool
  (match mode
    [(BackendModeAvx512) true]
    [_ false]))

(define (compiler-backend-defdispatch-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : i64]) : i64 (+ x 2))
(define (dot-avx512 [x : i64]) : i64 (+ x 5))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main) : i64 (dot 40))")

(define (compiler-backend-defdispatch-thunk-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-defdispatch-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "__tl_dispatch_cache_dot")
          (compiler-backend-string-contains? asm "__tl_dispatch_variant_avx2")
          (compiler-backend-string-contains? asm "__tl_dispatch_variant_avx512")
          (compiler-backend-string-contains? asm "    cpuid\n")
          (compiler-backend-string-contains? asm "    xgetbv\n")
          (compiler-backend-string-contains? asm "    call *(%r11)\n")
          (compiler-backend-string-contains? asm "    vzeroupper\n")
          (compiler-backend-string-contains? asm "main:\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-dispatch-variant-mode-ok?) : bool
  (and
    (backend-and4
      (compiler-backend-test-mode-avx2?
        (compiler-backend-effective-mode-for-function-name
          (BackendModeScalar)
          "__tl_dispatch_variant_avx2_dot__dot-avx2"))
      (compiler-backend-test-mode-avx512?
        (compiler-backend-effective-mode-for-function-name
          (BackendModeScalar)
          "__tl_dispatch_variant_avx512_dot__dot-avx512"))
      (compiler-backend-test-mode-scalar?
        (compiler-backend-effective-mode-for-function-name
          (BackendModeScalar)
          "__tl_dispatch_variant_scalar_dot__dot-scalar"))
      (compiler-backend-test-mode-avx2?
        (compiler-backend-effective-mode-for-function-name
          (BackendModeAvx2)
          "ordinary")))
    (compiler-backend-defdispatch-thunk-ok?)))

(define (compiler-backend-signature-i64-to-i64?
  [sig : CompilerBackendMaybeSignature]) : bool
  (match sig
    [(CompilerBackendSomeSignature args ret-ty)
      (match ret-ty
        [(AstTyI64)
          (match args
            [(AstTypeCons arg rest)
              (match (ty-node-get arg)
                [(AstTyI64)
                  (match (box-get rest)
                    [(AstTypeNil) true]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]
    [(CompilerBackendNoSignature) false]))

(define (compiler-backend-signature-unit-to-i64?
  [sig : CompilerBackendMaybeSignature]) : bool
  (match sig
    [(CompilerBackendSomeSignature args ret-ty)
      (match args
        [(AstTypeNil)
          (match ret-ty
            [(AstTyI64) true]
            [_ false])]
        [_ false])]
    [(CompilerBackendNoSignature) false]))

(define (compiler-backend-program-index-test-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (IrFunction
      "pkg/really-long-backend-index-function"
      (compiler-ir-param-cons (IrParam "x" (AstTyI64) 0) IrParamNil)
      (AstTyI64)
      1
      IrBlockNil)
    (compiler-ir-function-cons
      (IrFunction "short_fn" IrParamNil (AstTyUnit) 0 IrBlockNil)
      IrFunctionNil)))

(define (compiler-backend-program-index-test-externs) : CompilerIrExternList
  (compiler-ir-extern-cons
    (IrExtern
      "provided_decl"
      (ast-ty-func AstTypeNil (AstTyI64))
      (AstExternAbiC)
      "provided_link"
      AstExternLinkInputNil
      true)
    (compiler-ir-extern-cons
      (IrExtern
        "referenced_decl"
        (ast-ty-func (ast-type-cons (AstTyI64) AstTypeNil) (AstTyI64))
        (AstExternAbiC)
        "referenced_link"
        AstExternLinkInputNil
        false)
      IrExternNil)))

(define (compiler-backend-user-symbol-cache-ok?) : bool
  (begin
    (intern-reset!)
    (compiler-backend-user-symbol-cache-reset!)
    (let
      [path-name : String "pkg/nested/module.tl::some-value"]
      [path-id : i64 (intern path-name)]
      [path-symbol-first : String (compiler-backend-user-symbol-id path-id)]
      [count-after-path-first : i64 (compiler-backend-user-symbol-cache-count)]
      [path-symbol-second : String (compiler-backend-user-symbol-id path-id)]
      [count-after-path-second : i64 (compiler-backend-user-symbol-cache-count)]
      [main-id : i64 (intern "main")]
      [main-symbol-first : String (compiler-backend-user-symbol-id main-id)]
      [count-after-main-first : i64 (compiler-backend-user-symbol-cache-count)]
      [main-symbol-second : String (compiler-backend-user-symbol-id main-id)]
      [count-after-main-second : i64 (compiler-backend-user-symbol-cache-count)]
      [wrapper-symbol : String (compiler-backend-user-symbol path-name)]
      [count-after-wrapper : i64 (compiler-backend-user-symbol-cache-count)]
      (backend-and8
        (string-eq path-symbol-first "_tl_pkg_nested_module_some_value")
        (string-eq path-symbol-second path-symbol-first)
        (= count-after-path-first 1)
        (= count-after-path-second count-after-path-first)
        (string-eq main-symbol-first "main")
        (string-eq main-symbol-second "main")
        (= count-after-main-second count-after-main-first)
        (and
          (string-eq wrapper-symbol path-symbol-first)
          (= count-after-wrapper count-after-main-second))))))

(define (compiler-backend-program-index-id-maps-ok?) : bool
  (let
    [fn-name : String "pkg/really-long-backend-index-function"]
    [fn-id : i64 (intern fn-name)]
    [provided-name : String "provided_decl"]
    [provided-id : i64 (intern provided-name)]
    [provided-link-id : i64 (intern "provided_link")]
    [referenced-name : String "referenced_decl"]
    [referenced-id : i64 (intern referenced-name)]
    [referenced-link : String "referenced_link"]
    [referenced-link-id : i64 (intern referenced-link)]
    [missing-id : i64 (intern "missing_backend_index_name")]
    [index : CompilerBackendProgramIndex
      (compiler-backend-program-index-build
        (compiler-backend-program-index-test-functions)
        (compiler-backend-program-index-test-externs))]
    (and
      (backend-and8
        (compiler-backend-index-function-defines-id? index fn-id)
        (compiler-backend-index-function-defines? index fn-name)
        (not (compiler-backend-index-function-defines-id? index missing-id))
        (compiler-backend-signature-i64-to-i64?
          (compiler-backend-index-function-signature-id index fn-id))
        (compiler-backend-signature-i64-to-i64?
          (compiler-backend-index-function-signature index fn-name))
        (string-eq
          (compiler-backend-function-symbol-index index fn-name)
          "_tl_f0")
        (string-eq (compiler-backend-function-label-scope index fn-name) "f0")
        (compiler-backend-signature-unit-to-i64?
          (compiler-backend-index-extern-signature-id index provided-id)))
      (backend-and8
        (compiler-backend-index-extern-provided-id? index provided-id)
        (compiler-backend-index-extern-provided? index provided-name)
        (not
          (compiler-backend-index-extern-provided-id? index provided-link-id))
        (compiler-backend-index-extern-references-id? index referenced-id)
        (compiler-backend-index-extern-references-id? index referenced-link-id)
        (string-eq
          (compiler-backend-index-extern-link-symbol-id index referenced-id)
          referenced-link)
        (string-eq
          (compiler-backend-index-extern-link-symbol-id
            index
            referenced-link-id)
          referenced-link)
        (string-eq
          (compiler-backend-index-extern-link-symbol-id index missing-id)
          "missing_backend_index_name"))
      (backend-and4
        (string-eq
          (compiler-backend-function-symbol-map-comment index fn-name)
          "#t _tl_f0 _tl_really_long_backend_index_function\n")
        (string-eq
          (compiler-backend-function-symbol-index index provided-name)
          "provided_link")
        true
        true))))

(define (compiler-backend-program-index-interns-bound-names-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [fn-name : String "late_backend_index_fn"]
      [extern-name : String "late_backend_index_ext"]
      [extern-link : String "late_backend_index_link"]
      [index : CompilerBackendProgramIndex
        (compiler-backend-program-index-build
          (compiler-ir-function-cons
            (IrFunction fn-name IrParamNil (AstTyUnit) 0 IrBlockNil)
            IrFunctionNil)
          (compiler-ir-extern-cons
            (IrExtern
              extern-name
              (ast-ty-func AstTypeNil (AstTyI64))
              (AstExternAbiC)
              extern-link
              AstExternLinkInputNil
              false)
            IrExternNil))]
      [fn-id : i64 (intern fn-name)]
      [extern-id : i64 (intern extern-name)]
      [extern-link-id : i64 (intern extern-link)]
      (backend-and8
        (compiler-backend-index-function-defines-id? index fn-id)
        (compiler-backend-index-function-defines? index fn-name)
        (compiler-backend-signature-unit-to-i64?
          (compiler-backend-index-extern-signature-id index extern-id))
        (compiler-backend-index-extern-references-id? index extern-id)
        (compiler-backend-index-extern-references-id? index extern-link-id)
        (string-eq
          (compiler-backend-index-extern-link-symbol-id index extern-id)
          extern-link)
        (string-eq
          (compiler-backend-index-extern-link-symbol-id index extern-link-id)
          extern-link)
        (compiler-backend-index-extern-references? index extern-link)))))

(define (compiler-backend-profile-runtime-source) : String
  "(extern (tl_profile_alloc_total) : i64)
(define (main) : i64 (tl_profile_alloc_total))")

(define (compiler-backend-profile-runtime-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-profile-runtime-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains?
            asm
            ".globl tl_profile_alloc_total\n")
          (compiler-backend-string-contains? asm "tl_profile_alloc_total:\n")
          (compiler-backend-string-contains? asm "tl_profile_alloc_live:\n")
          (compiler-backend-string-contains? asm "tl_profile_alloc_peak:\n")
          (compiler-backend-string-contains?
            asm
            "tl_profile_alloc_reset_peak:\n")
          (not
            (compiler-backend-string-contains? asm ".globl tl_profile_now_ms\n"))
          (not (compiler-backend-string-contains? asm "tl_profile_now_ms:\n"))
          (not
            (compiler-backend-string-contains? asm "QueryPerformanceCounter")))
        (not
          (compiler-backend-string-contains? asm "QueryPerformanceFrequency")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-profile-runtime-split-ok?) : bool
  (and
    (compiler-backend-profile-runtime-target-ok? (BackendTargetLinux))
    (compiler-backend-profile-runtime-target-ok? (BackendTargetWindows))))

(define (compiler-backend-self-test) : i64
  (if (and
    (backend-and8
      (and
        (compiler-backend-global-type-list-boxed-ok?)
        (compiler-backend-target-model-ok? (compiler-backend-smoke-source)))
      (compiler-backend-array-access-asm-ok?)
      (compiler-backend-make-array-ok?)
      (compiler-backend-source-ok? (compiler-backend-smoke-source))
      (and
        (compiler-backend-object-image-shape-ok?)
        (compiler-object-coff-smoke-ok?)
        (compiler-object-coff-text-smoke-ok?)
        (compiler-backend-coff-renders-real-text-ok?)
        (compiler-backend-windows-object-entry-unwind-ok?)
        (compiler-object-elf-smoke-ok?)
        (compiler-object-elf-text-smoke-ok?)
        (compiler-backend-elf-renders-real-text-ok?)
        (compiler-backend-pic-ok?)
        (compiler-backend-deterministic-ok? (compiler-backend-smoke-source)))
      (compiler-backend-string-ok?)
      (and
        (compiler-backend-memory-op-ok?)
        (compiler-backend-address-mode-fusion-ok?)
        (compiler-backend-scratch-staging-direct-home-shape-ok?)
        (compiler-backend-low-level-instr-ok?)
        (compiler-backend-syscall-source-ok?)
        (compiler-backend-numeric-cast-shape-ok?)
        (compiler-backend-implicit-main-ok?))
      (and
        (compiler-backend-aggregate-ok?)
        (compiler-backend-pack-immediate-word-shape-ok?)))
    (backend-and8
      (compiler-backend-literal-payload-ok?)
      (and
        (compiler-backend-enum-match-ok?)
        (compiler-backend-never-branch-register-group-ok?))
      (and
        (compiler-backend-regalloc-ok?)
        (compiler-backend-callee-save-pop-epilogue-ok?))
      (compiler-backend-peephole-ok?)
      (and
        (compiler-backend-phi-parallel-copy-ok?)
        (compiler-backend-phi-group-cycle-copy-ok?)
        (compiler-backend-branch-phi-edge-copy-ok?)
        (compiler-backend-phi-immediate-stack-copy-ok?)
        (compiler-backend-phi-direct-scalar-copy-ok?)
        (compiler-backend-single-phi-return-shortcut-ok?)
        (compiler-backend-multi-phi-return-shortcut-ok?)
        (compiler-backend-phi-return-rejects-work-ok?)
        (compiler-backend-mov-phi-copy-fusion-ok?))
      (and
        (compiler-backend-f64-ok?)
        (compiler-backend-f64-neg-sign-mask-ok?)
        (compiler-backend-f32-literal-binop-ok?)
        (compiler-backend-bitcast-shape-ok?))
      (compiler-backend-bool-control-flow-ok?)
      (and
        (compiler-backend-stack-args-ok?)
        (compiler-backend-direct-tail-call-ok?)
        (compiler-backend-indirect-tail-call-ok?)))
    (backend-and8
      (and
        (compiler-backend-instr-diagnostics-ok?)
        (compiler-backend-register-group-fail-closed-ok?)
        (compiler-backend-ir-walkers-fail-closed-ok?))
      (compiler-backend-optimizer-rewrite-diagnostic-ok?)
      (and
        (compiler-backend-runtime-helper-asm-ok?)
        (compiler-backend-str-view-runtime-helper-asm-ok?)
        (compiler-backend-runtime-helper-inventory-ok?)
        (compiler-backend-runtime-page-call-inventory-ok?)
        (compiler-backend-profile-runtime-split-ok?))
      (compiler-backend-alloc-runtime-arena-ok?)
      (compiler-backend-region-ok?)
      (compiler-backend-process-fallback-absent-ok?)
      (compiler-backend-windows-process-fallback-absent-ok?)
      (and
        (compiler-backend-append-file-status-ok?)
        (compiler-backend-private-io-fs-runtime-labels-ok?)))
    (compiler-backend-fs-runtime-ok?)
    (compiler-backend-windows-fs-runtime-ok?)
    (compiler-backend-fs-read-dir-runtime-removed-ok?)
    (compiler-backend-fs-metadata-runtime-removed-ok?)
    (compiler-backend-fs-current-dir-extern-only-ok?)
    (compiler-backend-windows-fs-current-dir-extern-only-ok?)
    (backend-and8
      (compiler-backend-user-helper-name-ok?)
      (compiler-backend-file-handle-open-close-runtime-ok?)
      (and
        (compiler-backend-string-runtime-ok?)
        (compiler-backend-shadowed-string-helpers-ok?)
        (compiler-backend-windows-print-runtime-ok?))
      (and
        (compiler-backend-env-runtime-ok?)
        (compiler-backend-stdlib-env-runtime-ok?))
      (compiler-backend-expanded-scalar-regs-ok?)
      (compiler-backend-regalloc-f64-ok?)
      (compiler-backend-runtime-coexist-ok?)
      (and
        (compiler-backend-module-symbol-ok?)
        (compiler-backend-clean-module-symbol-collision-ok?)
        (compiler-backend-program-argv-entry-capture-ok?)
        (compiler-backend-arg-runtime-abort-ok?)))
    (compiler-backend-windows-env-runtime-ok?)
    (compiler-backend-extern-metadata-symbol-ok?)
    (compiler-backend-extern-value-fnptr-ok?)
    (compiler-backend-varargs-ffi-ok?)
    (compiler-backend-c-abi-aggregate-ok?)
    (compiler-backend-c-abi-sret-aggregate-windows-ok?)
    (compiler-backend-c-abi-byref-aggregate-arg-windows-ok?)
    (compiler-backend-c-abi-win64-enum-aggregate-ok?)
    (compiler-backend-c-abi-sysv-register-aggregate-arg-linux-ok?)
    (compiler-backend-c-abi-sysv-memory-aggregate-arg-linux-ok?)
    (compiler-backend-c-abi-sysv-two-register-return-linux-ok?)
    (backend-and4
      (compiler-backend-string-ref-shape-ok?)
      (compiler-backend-fixed-array-shape-ok?)
      (compiler-backend-raw-pointer-fixture-shape-ok?)
      (and
        (compiler-backend-box-ok?)
        (compiler-backend-inline-aggregate-storage-ok?)))
    (compiler-backend-tuple-ok?)
    (compiler-backend-export-symbol-tests-ok?)
    (compiler-backend-closure-emit-shape-ok?)
    (compiler-backend-alloc-runtime-shape-ok?)
    (backend-and8
      (compiler-backend-scalar-wide-ops-ok?)
      (and
        (compiler-backend-scalar-div-mod-ok?)
        (compiler-backend-constant-divisor-strength-ok?)
        (compiler-backend-safe-divrem-guard-elision-ok?))
      (and
        (compiler-backend-i64-immediate-load-shape-ok?)
        (compiler-backend-narrow-scalar-instr-ok?)
        (compiler-backend-global-compare-width-ok?))
      (and
        (compiler-backend-f64-abi-ok?)
        (compiler-backend-register-f64-aggregate-ok?)
        (compiler-backend-register-f32-aggregate-ok?))
      (compiler-backend-win64-f64-abi-ok?)
      (compiler-backend-aggregate-storage-shape-ok?)
      (compiler-backend-shift-guard-ok?)
      (and
        (compiler-backend-windows-runtime-guard-ok?)
        (compiler-backend-simd-vector-ok?)
        (compiler-backend-dispatch-variant-mode-ok?)
        (compiler-backend-user-symbol-cache-ok?)
        (compiler-backend-program-index-id-maps-ok?)
        (compiler-backend-program-index-interns-bound-names-ok?))))
    42
    (begin
      (panic "backend: smoke output mismatch")
      ;; lint-allow: unreachable-code
      0)))