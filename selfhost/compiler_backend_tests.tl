;; compiler_backend_tests.tl - Selfhost backend test helpers split from production backend.
(import "compiler_backend.tl")

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
  (add8 1 2 3 4 5 6 7 8))")

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
  (mix 1 2 3 4 5 6 7 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0))")

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
    (and (and (< 8.5 i) (< i 9.5)) (and (< 9.5 j) (< j 10.5)))
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
  (if (and (< 8.5 f8) (< f8 9.5)) i6 0))
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

(define (compiler-backend-raw-pointer-fixture-source) : String
  "(extern tl_alloc : (-> i64 (MutPtr u8)))

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

(define (compiler-backend-asm-ok? [asm : String]) : bool
  (and
    (backend-and8
      (compiler-backend-string-contains? asm ".data\n")
      (compiler-backend-string-contains? asm ".text\n")
      (compiler-backend-string-contains? asm ".globl _start\n")
      (compiler-backend-string-contains? asm "_start:\n")
      (compiler-backend-string-contains? asm "main:\n")
      (compiler-backend-string-contains? asm "_tl_inc:\n")
      (compiler-backend-string-contains? asm "_tl_answer:\n")
      (compiler-backend-string-contains? asm "    call _tl_inc\n"))
    (backend-and4
      (compiler-backend-string-contains? asm "    jge .Lmain_while_exit.2\n")
      (compiler-backend-string-contains? asm "    jle .Lmain_if_else.4\n")
      (compiler-backend-string-contains? asm "    jmp .Lmain_while_header.0\n")
      true)))

(define (compiler-backend-source-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm) (compiler-backend-asm-ok? asm)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-string-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-string-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".L_tl_str_data_6869:")
        (and
          (compiler-backend-string-contains? asm ".L_tl_str_6869:")
          (and
            (compiler-backend-string-contains? asm "    .string \"hi\"\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    .quad .L_tl_str_data_6869\n")
              (and
                (compiler-backend-string-contains? asm "    .quad 2\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "_tl_greeting:\n    .quad .L_tl_str_6869\n")
                  (compiler-backend-string-contains?
                    asm
                    "    leaq .L_tl_str_6869(%rip), %rax\n")))))))]
    [(ErrCompilerBackend _) false]))

;; Backend-owned replacement for the string runtime helper emission tests
;; (#1044): source-level string builtins lower to direct calls, and the backend
;; emits each helper body instead of leaving an extern placeholder.
(define (compiler-backend-string-runtime-source) : String
  "(define (parse-and-render [s : String]) : i64
  (+
    (string->int s)
    (+
      (string-length (int->string 42))
      (+
        (string-length (substring s 0 1))
        (string-length (string-concat s \"!\"))))))
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
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".globl tl_string_to_int\n")
          (compiler-backend-string-contains? asm "tl_string_to_int:\n")
          (compiler-backend-string-contains? asm "    call tl_string_to_int\n")
          (compiler-backend-string-contains? asm ".globl tl_int_to_string\n")
          (compiler-backend-string-contains? asm "tl_int_to_string:\n")
          (compiler-backend-string-contains? asm "    call tl_int_to_string\n")
          (compiler-backend-string-contains? asm ".globl tl_substring\n")
          (compiler-backend-string-contains? asm "    call tl_substring\n"))
        (and
          (backend-and8
            (compiler-backend-string-contains? asm "tl_substring:\n")
            (compiler-backend-string-contains? asm ".globl tl_string_concat\n")
            (compiler-backend-string-contains? asm "tl_string_concat:\n")
            (compiler-backend-string-contains?
              asm
              "    call tl_string_concat\n")
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_string_to_int\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_int_to_string\n"))
            (not
              (compiler-backend-string-contains? asm ".extern tl_substring\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_string_concat\n")))
          (and
            (backend-and4
              (compiler-backend-string-contains? asm ".globl tl_print_str\n")
              (compiler-backend-string-contains? asm "tl_print_str:\n")
              (compiler-backend-string-contains? asm "    call tl_print_str\n")
              (not
                (compiler-backend-string-contains? asm ".extern tl_print_str\n")))
            (not
              (compiler-backend-string-contains?
                asm
                (compiler-backend-todo-marker))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-print-runtime-source) : String
  "(define (main) : i64
  (begin
    (print-char #A')
    (print-float 1.5)
    0))")

(define (compiler-backend-print-runtime-target-extra-ok?
  [target : CompilerBackendTarget]
  [asm : String]) : bool
  (match target
    [(BackendTargetLinux)
      (compiler-backend-string-contains? asm "    call snprintf\n")]
    [(BackendTargetWindows)
      (and
        (compiler-backend-string-contains? asm ".extern _snprintf\n")
        (compiler-backend-string-contains? asm "    call _snprintf\n"))]))

(define (compiler-backend-print-runtime-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-print-runtime-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".globl tl_print_char\n")
          (compiler-backend-string-contains? asm "tl_print_char:\n")
          (compiler-backend-string-contains? asm "    call tl_print_char\n")
          (compiler-backend-string-contains? asm ".globl tl_print_f64\n")
          (compiler-backend-string-contains? asm "tl_print_f64:\n")
          (compiler-backend-string-contains? asm "    call tl_print_f64\n")
          (compiler-backend-string-contains? asm ".L_tl_print_f64_fmt:\n")
          (compiler-backend-print-runtime-target-extra-ok? target asm))
        (and
          (not (compiler-backend-string-contains? asm "call _tl_print_char"))
          (and
            (not (compiler-backend-string-contains? asm "_tl_print_float"))
            (not (compiler-backend-string-contains? asm "call _tl_print_f64")))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-print-runtime-ok?) : bool
  (and
    (compiler-backend-print-runtime-target-ok? (BackendTargetLinux))
    (compiler-backend-print-runtime-target-ok? (BackendTargetWindows))))

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
          (compiler-backend-string-contains? asm ".L_tl_str_data_617a:")
          (compiler-backend-string-contains? asm ".L_tl_str_617a:")
          (compiler-backend-string-contains? asm "    .string \"az\"\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_str_data_617a\n")
          (compiler-backend-string-contains? asm "    cmpq %r11, %rax\n")
          (compiler-backend-string-contains?
            asm
            "    jb .L_tl_pick_str_bounds_ok")
          (compiler-backend-string-contains? asm "    call tl_oob_abort")
          (compiler-backend-string-contains? asm "tl_oob_abort:\n"))
        (and
          (backend-and4
            (compiler-backend-string-contains? asm "    movq 8(%r10), %rax\n")
            (compiler-backend-string-contains? asm "(%r10)")
            (compiler-backend-string-contains? asm "movzbq")
            (not (compiler-backend-string-contains? asm "movsbq (%r10)")))
          (and
            (not
              (compiler-backend-string-contains?
                asm
                "    jl .L_tl_pick_str_bounds_ok"))
            (not
              (compiler-backend-string-contains?
                asm
                (compiler-backend-todo-marker))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-aggregate-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-aggregate-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains?
            asm
            "    movq $16, %rdi\n    call tl_alloc\n")
          (compiler-backend-string-contains?
            asm
            ".globl _tl___enum_obj_Shape_Nothing\n")
          (compiler-backend-string-contains?
            asm
            "    leaq _tl___enum_obj_Shape_Nothing(%rip), %rax\n")
          (compiler-backend-string-contains? asm "    movq $1, (%r10)\n")
          (compiler-backend-string-contains? asm "    movq $2, (%r10)\n")
          (compiler-backend-string-contains? asm "    movq %rax, 8(%r10)\n")
          (not (compiler-backend-string-contains? asm "    call _tl_Point\n"))
          (not (compiler-backend-string-contains? asm "    call _tl_Nothing\n")))
        (and
          (not (compiler-backend-string-contains? asm "    call _tl_Circle\n"))
          (not (compiler-backend-string-contains? asm "    call _tl_Pair\n"))))]
    [(ErrCompilerBackend _) false]))

;; Backend-owned replacement for representative aggregate storage emit-shape
;; checks from the Rust backend suite (#1354/#1413).
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
          (compiler-backend-string-contains? asm "    call tl_alloc")
          (compiler-backend-string-contains? asm "tl_alloc:")
          (compiler-backend-string-contains? asm "movq $16")
          (compiler-backend-string-contains? asm "movq $7,")
          (compiler-backend-string-contains? asm "movq $1,")
          (compiler-backend-string-contains? asm "movq $2,")
          (compiler-backend-string-contains? asm ".L_tl_str_data_6869:")
          (compiler-backend-string-contains? asm "    .quad 2\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-aggregate-global-init-source) : String
  "(defenum MaybeI64 (Some i64) (None))
(defstruct Pair (x i64) (y i64))
(defstruct Nested (label String) (choice MaybeI64))

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
        (compiler-backend-string-contains?
          asm
          (backend-cat3 "    .comm " symbol ", 8, 8\n"))
        (compiler-backend-string-contains?
          asm
          (backend-cat3 "    call " init-symbol "\n"))
        (compiler-backend-string-contains?
          asm
          (backend-cat3 "    movq %rax, " symbol "(%rip)\n"))
        (compiler-backend-string-contains?
          asm
          (backend-cat3 init-symbol ":\n" "")))
      (compiler-backend-string-contains?
        asm
        (backend-cat3 "    movq " symbol "(%rip), %rax\n")))))

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
          (compiler-backend-string-contains?
            asm
            "_start:\n    call _tl___global_init_greeting\n")
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
          (compiler-backend-string-contains? asm "_tl___tl_lambda_main_0:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_desc___tl_lambda_main_0:\n")
          (compiler-backend-string-contains?
            asm
            "    .quad .L_tl_fn_entry___tl_lambda_main_0\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fn_entry___tl_lambda_main_0:\n")
          (compiler-backend-string-contains?
            asm
            "    call _tl___tl_lambda_main_0\n")
          (compiler-backend-string-contains?
            asm
            "    leaq .L_tl_fn_desc___tl_lambda_main_0(%rip), ")
          (compiler-backend-string-contains? asm "    call *%rax\n")
          (compiler-backend-string-contains? asm "    movq (%r11), %rax\n"))
        (and
          (compiler-backend-string-contains? asm "    movq 8(%r11), %rdi\n")
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-closure-inferred-shape-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-closure-inferred-source))
    [(OkCompilerBackend asm)
      (backend-and4
        (compiler-backend-string-contains? asm "_tl___tl_lambda_main_0:\n")
        (compiler-backend-string-contains?
          asm
          "    call _tl___tl_lambda_main_0\n")
        (compiler-backend-string-contains? asm "    call *%rax\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-closure-aggregate-return-shape-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-closure-aggregate-return-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "_tl___tl_lambda_main_0:\n")
          (compiler-backend-string-contains? asm "_tl___tl_lambda_main_1:\n")
          (compiler-backend-string-contains? asm "_tl___tl_lambda_main_2:\n")
          (compiler-backend-string-contains? asm "_tl___tl_lambda_main_3:\n")
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
        (and
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
          (and
            (backend-and4
              (compiler-backend-string-contains? asm "tl_alloc:\n")
              (>= (compiler-backend-string-count asm "    call tl_alloc\n") 4)
              (>= (compiler-backend-string-count asm "    call *%rax\n") 4)
              (not
                (compiler-backend-string-contains?
                  asm
                  (compiler-backend-todo-marker))))
            true)))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-closure-emit-shape-ok?) : bool
  (and
    (compiler-backend-closure-literal-shape-ok?)
    (and
      (compiler-backend-closure-inferred-shape-ok?)
      (compiler-backend-closure-aggregate-return-shape-ok?))))

(define (compiler-backend-enum-match-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-enum-match-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm "_tl_score:\n")
        (compiler-backend-string-contains? asm ".L_tl_score_match_arm.")
        (compiler-backend-string-contains? asm "    cmpq $0, (%r10)\n")
        (compiler-backend-string-contains?
          asm
          "    jne .L_tl_score_match_next.2\n")
        (compiler-backend-string-contains? asm "    movq 8(%r10), %rax\n")
        (not (compiler-backend-string-contains? asm "    call _tl_None\n"))
        (not (compiler-backend-string-contains? asm "    call _tl_Some\n"))
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-regalloc-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-regalloc-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "_tl_calc:\n")
        (and
          (compiler-backend-string-contains? asm "    movq %rdi, -8(%rbp)\n")
          (and
            (compiler-backend-string-contains? asm "    movq %rsi, -16(%rbp)\n")
            (and
              (compiler-backend-string-contains? asm "    movq %r12, -")
              (and
                (compiler-backend-string-contains? asm "    movq %rax, %r12\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    movq %r12, %rax\n")
                  (and
                    (not
                      (compiler-backend-string-contains?
                        asm
                        "    movq %rdi, %r12\n"))
                    (not
                      (compiler-backend-string-contains?
                        asm
                        "    movq %rsi, %r12\n")))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-regalloc-f64-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-regalloc-f64-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "main:\n")
        (and
          (compiler-backend-string-contains? asm "    movsd %xmm0, %xmm2\n")
          (and
            (compiler-backend-string-contains? asm "    movsd %xmm0, %xmm3\n")
            (and
              (compiler-backend-string-contains? asm "    movsd %xmm2, %xmm0\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    movsd %xmm3, %xmm1\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    addsd %xmm1, %xmm0\n")
                  (not
                    (compiler-backend-string-contains?
                      asm
                      "    movsd %xmm0, -8(%rbp)\n"))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-peephole-assignments) : CompilerRegAssignmentList
  (CompilerRegAssignmentCons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (CompilerRegAssignmentCons
      (CompilerRegAssignment 1 (CompilerRegRegister "%xmm2"))
      (CompilerRegAssignmentCons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r13"))
        CompilerRegAssignmentNil))))

(define (compiler-backend-expanded-scalar-assignments) : CompilerRegAssignmentList
  (CompilerRegAssignmentCons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r8"))
    (CompilerRegAssignmentCons
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
      (and
        (string-eq
          (compiler-backend-emit-store-var-with-plan assignments 1 "%rax")
          "    movq %rax, %r9\n")
        (and
          (string-eq
            (compiler-backend-emit-load-register "%r8" (AstTyU32))
            "    movl %r8d, %eax\n")
          (and
            (not (compiler-backend-plan-uses-callee-regs? assignments))
            (= (compiler-backend-frame-slots 2 assignments) 2)))))))

(define (compiler-backend-peephole-register-moves-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-peephole-assignments)]
    [coalesced : CompilerRegAssignmentList
      (CompilerRegAssignmentCons
        (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
        (CompilerRegAssignmentCons
          (CompilerRegAssignment 2 (CompilerRegRegister "%r12"))
          CompilerRegAssignmentNil))]
    (and
      (string-eq
        (compiler-backend-emit-load-var-with-plan assignments 0 "%r12")
        "")
      (and
        (string-eq
          (compiler-backend-emit-store-var-with-plan assignments 0 "%r12")
          "")
        (and
          (string-eq
            (compiler-backend-emit-load-f64-var-with-plan assignments 1 "%xmm0")
            "    movsd %xmm2, %xmm0\n")
          (and
            (string-eq
              (compiler-backend-emit-store-f64-var-with-plan
                assignments
                1
                "%xmm0")
              "    movsd %xmm0, %xmm2\n")
            (and
              (match (compiler-backend-emit-mov
                coalesced
                2
                (IrValueVar 0)
                (AstTyI64))
                [(OkCompilerBackend asm) (string-eq asm "")]
                [(ErrCompilerBackend _) false])
              (match (compiler-backend-emit-cast
                "_tl_test"
                "entry"
                coalesced
                2
                (IrValueVar 0)
                (AstTyI64)
                (AstTyI64))
                [(OkCompilerBackend asm) (string-eq asm "")]
                [(ErrCompilerBackend _) false]))))))))

(define (compiler-backend-peephole-asm-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-peephole-assignments)]
    (match (compiler-backend-emit-binop
      (CompilerRegVarTypeNil)
      assignments
      2
      (IrBinAdd)
      (IrValueVar 0)
      (IrValueI64 5)
      (AstTyI64))
      [(OkCompilerBackend add-asm)
        (match (compiler-backend-emit-binop
          (CompilerRegVarTypeNil)
          assignments
          2
          (IrBinMul)
          (IrValueVar 0)
          (IrValueI64 3)
          (AstTyI64))
          [(OkCompilerBackend mul-asm)
            (match (compiler-backend-emit-binop
              (CompilerRegVarTypeNil)
              assignments
              2
              (IrBinShl)
              (IrValueVar 0)
              (IrValueI64 2)
              (AstTyI64))
              [(OkCompilerBackend shl-asm)
                (match (compiler-backend-emit-binop
                  (CompilerRegVarTypeNil)
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
                            "    addq $5, %rax\n")
                          (and
                            (not
                              (compiler-backend-string-contains?
                                add-asm
                                "    movq $5, %rbx\n"))
                            (and
                              (compiler-backend-string-contains?
                                mul-asm
                                "    imulq $3, %rax\n")
                              (and
                                (not
                                  (compiler-backend-string-contains?
                                    mul-asm
                                    "    movq $3, %rbx\n"))
                                (and
                                  (compiler-backend-string-contains?
                                    shl-asm
                                    "    shlq $2, %rax\n")
                                  (and
                                    (not
                                      (compiler-backend-string-contains?
                                        shl-asm
                                        "    movq $2, %rbx\n"))
                                    (and
                                      (compiler-backend-string-contains?
                                        cmp-asm
                                        "    cmpq $10, %rax\n    setl %al\n")
                                      (and
                                        (compiler-backend-string-contains?
                                          branch-asm
                                          "    testq %rax, %rax\n    jne ")
                                        (not
                                          (compiler-backend-string-contains?
                                            branch-asm
                                            "    cmpq $0, %rax\n    jne "))))))))))]
                      [(ErrCompilerBackend _) false])]
                  [(ErrCompilerBackend _) false])]
              [(ErrCompilerBackend _) false])]
          [(ErrCompilerBackend _) false])]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-peephole-ok?) : bool
  (and
    (compiler-backend-peephole-register-moves-ok?)
    (and
      (compiler-backend-peephole-asm-ok?)
      (and
        (compiler-backend-fallthrough-jump-ok?)
        (and
          (compiler-backend-branch-fallthrough-ok?)
          (and
            (compiler-backend-zero-load-ok?)
            (and
              (compiler-backend-zero-compare-ok?)
              (and
                (compiler-backend-call-return-ok?)
                (compiler-backend-global-immediate-store-ok?)))))))))

(define (compiler-backend-fallthrough-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        0
        (IrBlockCons
          (IrBlock "entry" (IrInstrCons (IrInstrJump "done") IrInstrNil))
          (IrBlockCons
            (IrBlock
              "done"
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueI64 7)))
                IrInstrNil))
            IrBlockNil)))
      IrFunctionNil)
    IrExternNil))

(define (compiler-backend-fallthrough-jump-ok?) : bool
  (match (compiler-backend-emit-program (compiler-backend-fallthrough-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".Lmain_done:\n")
        (not (compiler-backend-string-contains? asm "    jmp .Lmain_done\n")))]
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
              (and
                (not
                  (compiler-backend-string-contains?
                    false-fallthrough
                    "    jmp .Lbranch_else\n"))
                (and
                  (compiler-backend-string-contains?
                    true-fallthrough
                    "    je .Lbranch_else\n")
                  (not
                    (compiler-backend-string-contains?
                      true-fallthrough
                      "    jmp .Lbranch_then\n")))))]
          [(ErrCompilerBackend _) false])]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-zero-load-ok?) : bool
  (match (compiler-backend-emit-load-value-with-plan
    CompilerRegAssignmentNil
    (IrValueI64 0)
    "%rax")
    [(OkCompilerBackend asm) (string-eq asm "    xorq %rax, %rax\n")]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-zero-compare-ok?) : bool
  (match (compiler-backend-emit-binop
    (CompilerRegVarTypeNil)
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

(define (compiler-backend-call-return-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "callee"
        IrParamNil
        (AstTyI64)
        0
        (IrBlockCons
          (IrBlock
            "entry"
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueI64 7)))
              IrInstrNil))
          IrBlockNil))
      (IrFunctionCons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          1
          (IrBlockCons
            (IrBlock
              "entry"
              (IrInstrCons
                (IrInstrCall 0 "callee" IrValueNil (AstTyI64))
                (IrInstrCons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil)))
            IrBlockNil))
        IrFunctionNil))
    IrExternNil))

(define (compiler-backend-call-return-ok?) : bool
  (match (compiler-backend-emit-program (compiler-backend-call-return-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          "    call _tl_callee\n    leave\n    ret\n")
        (not
          (compiler-backend-string-contains?
            asm
            "    call _tl_callee\n    movq %rax,")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-phi-same-home-assignments) : CompilerRegAssignmentList
  (CompilerRegAssignmentCons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (CompilerRegAssignmentCons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r12"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-phi-same-home-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "join"
      (IrInstrCons
        (IrInstrPhi
          1
          (IrPhiInputCons (IrPhiInput (IrValueVar 0) "entry") IrPhiInputNil)
          (AstTyI64))
        IrInstrNil))
    IrBlockNil))

(define (compiler-backend-phi-cycle-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "join"
      (IrInstrCons
        (IrInstrPhi
          0
          (IrPhiInputCons (IrPhiInput (IrValueVar 1) "back") IrPhiInputNil)
          (AstTyI64))
        (IrInstrCons
          (IrInstrPhi
            1
            (IrPhiInputCons (IrPhiInput (IrValueVar 0) "back") IrPhiInputNil)
            (AstTyI64))
          IrInstrNil)))
    IrBlockNil))

(define (compiler-backend-phi-parallel-copy-ok?) : bool
  (match (compiler-backend-emit-phi-edge-copies
    (compiler-backend-phi-same-home-assignments)
    (compiler-backend-phi-same-home-blocks)
    "join"
    "entry")
    [(OkCompilerBackend same-home)
      (match (compiler-backend-emit-phi-edge-copies
        CompilerRegAssignmentNil
        (compiler-backend-phi-cycle-blocks)
        "join"
        "back")
        [(OkCompilerBackend cycle)
          (and
            (string-eq same-home "")
            (and
              (compiler-backend-string-contains?
                cycle
                "    movq -8(%rbp), %r11\n")
              (and
                (compiler-backend-string-contains?
                  cycle
                  "    movq -16(%rbp), %rax\n")
                (and
                  (compiler-backend-string-contains?
                    cycle
                    "    movq %rax, -8(%rbp)\n")
                  (compiler-backend-string-contains?
                    cycle
                    "    movq %r11, -16(%rbp)\n")))))]
        [(ErrCompilerBackend _) false])]
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
    (and
      (compiler-backend-reg-is?
        (compiler-backend-target-arg-reg (BackendTargetWindows) 0)
        "%rcx")
      (and
        (compiler-backend-reg-is?
          (compiler-backend-target-arg-reg (BackendTargetWindows) 3)
          "%r9")
        (and
          (compiler-backend-reg-err?
            (compiler-backend-target-arg-reg (BackendTargetWindows) 4))
          (and
            (= (compiler-backend-outgoing-shadow-space (BackendTargetLinux)) 0)
            (and
              (=
                (compiler-backend-outgoing-shadow-space (BackendTargetWindows))
                32)
              (and
                (compiler-backend-string-contains?
                  (compiler-backend-target-entry-text (BackendTargetLinux) true)
                  "_start")
                (and
                  (compiler-backend-string-contains?
                    (compiler-backend-target-entry-text
                      (BackendTargetWindows)
                      true)
                    ".globl main")
                  (and
                    (compiler-backend-target-linux-no-entry-ok? src)
                    (and
                      (compiler-backend-target-linux-matches-default? src)
                      (and
                        (compiler-backend-target-windows-abi-ok?)
                        (and
                          (compiler-backend-target-windows-callee-save-ok?)
                          (and
                            (compiler-backend-target-windows-stack-probe-ok?)
                            (compiler-backend-target-windows-runtime-ok?)))))))))))))))

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
            (and
              (compiler-backend-string-contains? asm "main:\n")
              (and
                (not (compiler-backend-string-contains? asm ".globl _start\n"))
                (not (compiler-backend-string-contains? asm "_start:\n")))))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-target-windows-stack-probe-ok?) : bool
  (let
    [win : String (compiler-backend-emit-stack-sub (BackendTargetWindows) 4800)]
    [linux : String (compiler-backend-emit-stack-sub (BackendTargetLinux) 4800)]
    (and
      (compiler-backend-string-contains? win "    movl $4800, %eax\n")
      (and
        (compiler-backend-string-contains? win "    callq __chkstk\n")
        (and
          (compiler-backend-string-contains? win "    subq %rax, %rsp\n")
          (and
            (not
              (compiler-backend-string-contains? win "    subq $4800, %rsp\n"))
            (and
              (compiler-backend-string-contains? linux "    subq $4800, %rsp\n")
              (not (compiler-backend-string-contains? linux "__chkstk")))))))))

(define (compiler-backend-target-windows-abi-source) : String
  "(extern ext : (-> i64 i64 i64 i64 i64 i64))
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
          (not (compiler-backend-string-contains? asm "_start:\n"))
          (not (compiler-backend-string-contains? asm "syscall\n"))
          (compiler-backend-string-contains? asm "    movq %rcx, -8(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq %rdx, -16(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq %r8, -24(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq %r9, -32(%rbp)\n")
          (compiler-backend-string-contains? asm "    movq 48(%rbp), %rax\n"))
        (and
          (compiler-backend-string-contains? asm "    movq %r11, 32(%rsp)\n")
          (compiler-backend-string-contains? asm "    call ext\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-windows-callee-save-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-callee-save-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movq %r12, -")
        (compiler-backend-string-contains? asm ", %r12\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-windows-runtime-ok?) : bool
  (match (compiler-backend-emit-program-for-target
    (compiler-backend-runtime-helper-program)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl tl_alloc\n")
        (and
          (compiler-backend-string-contains? asm "    call VirtualAlloc\n")
          (and
            (compiler-backend-string-contains? asm "    call _write\n")
            (and
              (compiler-backend-string-contains? asm "    call _read\n")
              (and
                (compiler-backend-string-contains? asm "    call fflush\n")
                (and
                  (compiler-backend-string-contains? asm "    call _open\n")
                  (and
                    (compiler-backend-string-contains?
                      asm
                      "    call _lseeki64\n")
                    (and
                      (compiler-backend-string-contains?
                        asm
                        "    call _access\n")
                      (and
                        (compiler-backend-string-contains?
                          asm
                          "tl_substring:\n")
                        (and
                          (compiler-backend-string-contains?
                            asm
                            "tl_string_concat:\n")
                          (and
                            (compiler-backend-string-contains?
                              asm
                              "tl_string_eq:\n")
                            (and
                              (compiler-backend-string-contains?
                                asm
                                "tl_string_to_int:\n")
                              (and
                                (compiler-backend-string-contains?
                                  asm
                                  "tl_int_to_string:\n")
                                (and
                                  (compiler-backend-string-contains?
                                    asm
                                    ".L_tl_arg:\n")
                                  (and
                                    (compiler-backend-string-contains?
                                      asm
                                      ".L_tl_read_file:\n")
                                    (and
                                      (compiler-backend-string-contains?
                                        asm
                                        ".L_tl_write_file:\n")
                                      (and
                                        (compiler-backend-string-contains?
                                          asm
                                          ".L_tl_file_exists:\n")
                                        (and
                                          (compiler-backend-string-contains?
                                            asm
                                            ".L_tl_file_open_status:\n")
                                          (and
                                            (compiler-backend-string-contains?
                                              asm
                                              ".L_tl_file_close_status:\n")
                                            (and
                                              (compiler-backend-string-contains?
                                                asm
                                                "    movq $-38, %rax\n")
                                              (and
                                                (compiler-backend-string-contains?
                                                  asm
                                                  ".L_tl_file_read_chunk_status:\n")
                                                (and
                                                  (compiler-backend-string-contains?
                                                    asm
                                                    ".L_tl_file_read_chunk_bytes:\n")
                                                  (and
                                                    (compiler-backend-string-contains?
                                                      asm
                                                      ".L_tl_file_read_chunk_eof:\n")
                                                    (and
                                                      (not
                                                        (compiler-backend-string-contains?
                                                          asm
                                                          ".L_tl_file_handle_next:\n"))
                                                      (and
                                                        (compiler-backend-string-contains?
                                                          asm
                                                          "    movq %rcx, .L_tl_argc(%rip)\n")
                                                        (and
                                                          (compiler-backend-string-contains?
                                                            asm
                                                            "    .extern VirtualAlloc\n")
                                                          (and
                                                            (not
                                                              (compiler-backend-string-contains?
                                                                asm
                                                                "syscall\n"))
                                                            (compiler-backend-windows-driver-runtime-ok?))))))))))))))))))))))))))))]
    [(ErrCompilerBackend message) false]))

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
        (IrFunctionCons
          (IrFunction
            "main"
            IrParamNil
            (AstTyI64)
            4
            (IrBlockCons
              (IrBlock "entry" (IrInstrCons instr IrInstrNil))
              IrBlockNil))
          IrFunctionNil)
        IrExternNil)]
    (match (compiler-backend-emit-program-with-spans program spans)
      [(ErrCompilerBackend diag)
        (and
          (string-eq (compiler-diagnostic-message diag) want-message)
          (and
            (= (compiler-diagnostic-line diag) want-line)
            (= (compiler-diagnostic-col diag) want-col)))]
      [(OkCompilerBackend _) false])))

(define (compiler-backend-instr-diagnostics-ok?) : bool
  (and
    (compiler-backend-instr-diagnostic-case-ok?
      (IrInstrMov 0 (IrValueF64 "1.0") (AstTyI64))
      "backend: f64 values are not supported yet"
      21
      7)
    (and
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
      (and
        (compiler-backend-instr-diagnostic-case-ok?
          (IrInstrUnOp 2 (IrUnNot) (IrValueF64 "1.0") (AstTyF64))
          "backend: unsupported f64 unary op"
          40
          11)
        (compiler-backend-instr-diagnostic-case-ok?
          (IrInstrLaneId 3 4 (AstTyI64))
          "backend: vector/mask IR emission is not implemented"
          44
          13)))))

(define (compiler-backend-avx2-map-source [elem : String]) : String
  (backend-cat5
    "(define (fill [a : (Array "
    elem
    ")] [b : (Array "
    elem
    (backend-cat3
      ")] [out : (Array "
      elem
      ")] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")))

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
    (and
      (compiler-backend-avx2-map-asm-contains?
        "i32"
        "    vmovdqu "
        "    vpaddd ")
      (compiler-backend-avx2-map-asm-contains?
        "f64"
        "    vmovupd "
        "    vaddpd "))))

(define (compiler-backend-avx512-map-asm-contains?
  [elem : String]
  [move : String]
  [op : String]) : bool
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
              (compiler-backend-string-contains? asm "kmovw")
              (compiler-backend-string-contains? asm "shll %cl, %eax"))
            (not
              (compiler-backend-string-contains?
                asm
                "vector/mask IR emission is not implemented")))]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerLower _) false]))

(define (compiler-backend-avx512-vector-map-ok?) : bool
  (and
    (compiler-backend-avx512-map-asm-contains?
      "i64"
      "    vmovdqu64 "
      "    vpaddq ")
    (and
      (compiler-backend-avx512-map-asm-contains?
        "i32"
        "    vmovdqu32 "
        "    vpaddd ")
      (compiler-backend-avx512-map-asm-contains?
        "f64"
        "    vmovupd "
        "    vaddpd "))))

(define (compiler-backend-avx2-reduce-asm-contains?
  [src : String]
  [op : String]
  [move : String]) : bool
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
              (compiler-backend-string-contains? asm "    vextracti128 $1, ")
              (compiler-backend-string-contains? asm "    vpsrldq $8, ")
              (compiler-backend-string-contains? asm op)
              (compiler-backend-string-contains? asm move)
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
      "    vmovq %xmm0, %rax\n")
    (and
      (compiler-backend-avx2-reduce-asm-contains?
        "(define (f [xs : (Array i32)] [n : i64]) : i32 (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))"
        "    vpaddd "
        "    vmovd %xmm0, %eax\n")
      (and
        (compiler-backend-avx2-reduce-asm-contains?
          "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
          "    vpminsd "
          "    vmovd %xmm0, %eax\n")
        (compiler-backend-avx2-reduce-asm-contains?
          "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
          "    vpmaxsd "
          "    vmovd %xmm0, %eax\n")))))

(define (compiler-backend-optimizer-rewrite-diagnostic-ok?) : bool
  (let
    [phi : CompilerIrInstr
      (IrInstrPhi
        0
        (IrPhiInputCons (IrPhiInput (IrValueF64 "1.0") "entry") IrPhiInputNil)
        (AstTyI64))]
    [program : CompilerIrProgram
      (IrProgram
        IrGlobalNil
        (IrFunctionCons
          (IrFunction
            "main"
            IrParamNil
            (AstTyI64)
            4
            (IrBlockCons
              (IrBlock "entry" (IrInstrCons (IrInstrJump "join") IrInstrNil))
              (IrBlockCons
                (IrBlock
                  "join"
                  (IrInstrCons
                    phi
                    (IrInstrCons
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
        (match (compiler-backend-emit-program-with-spans
          optimized
          optimized-spans)
          [(ErrCompilerBackend diag)
            (and
              (string-eq
                (compiler-diagnostic-message diag)
                "backend: f64 values are not supported yet")
              (and
                (= (compiler-diagnostic-line diag) 55)
                (= (compiler-diagnostic-col diag) 13)))]
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
      false)
    IrFunctionNil
    IrExternNil
    (compiler-source-spans-empty)
    (compiler-diagnostic-at-start "" ""))
    [(OkCompilerBackend asm) (compiler-backend-string-contains? asm needle)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-memory-op-ok?) : bool
  (and
    (compiler-backend-instr-contains?
      (IrInstrAddrOf 2 1)
      "    leaq -16(%rbp), %rax\n")
    (and
      (compiler-backend-instr-contains?
        (IrInstrGep 3 (IrValueVar 1) (IrValueI64 2) (AstTyI32))
        "    addq $8, %rax\n")
      (and
        (compiler-backend-instr-contains?
          (IrInstrGep 3 (IrValueVar 1) (IrValueVar 2) (AstTyI32))
          "    leaq (%rax,%rbx,4), %rax\n")
        (and
          (compiler-backend-instr-contains?
            (IrInstrLoad 4 (IrValueVar 1) (AstTyU8))
            "    movzbq (%r10), %rax\n")
          (and
            (compiler-backend-instr-contains?
              (IrInstrStorePtr (IrValueVar 1) (IrValueI64 7) (AstTyI32))
              "    movl $7, (%r10)\n")
            (and
              (compiler-backend-instr-contains?
                (IrInstrCast 6 (IrValueVar 5) (AstTyI8) (AstTyI64))
                "    movsbq -48(%rbp), %rax\n")
              (compiler-backend-instr-contains?
                (IrInstrBoundsCheck (IrValueVar 1) (IrValueVar 2) "bounds_ok")
                "    jb .L_tl_test_bounds_ok\n"))))))))

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
          (compiler-backend-string-contains? asm "_tl_use_fixed:\n")
          (compiler-backend-string-contains? asm "    movq $3, %r11\n")
          (compiler-backend-string-contains? asm "    cmpq %r11, %rax\n")
          (compiler-backend-string-contains? asm "    call tl_oob_abort\n")
          (compiler-backend-string-contains?
            asm
            "    leaq (%rax,%rbx,8), %rax\n")
          (compiler-backend-string-contains? asm "    movq %rax, (%r10)\n")
          (compiler-backend-string-contains? asm "    movq (%r10), %rax\n")
          (compiler-backend-string-contains? asm "tl_oob_abort:\n"))
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
        (and
          (compiler-backend-string-contains? asm "    call tl_alloc\n")
          (and
            (compiler-backend-string-contains? asm "call tl_oob_abort")
            (compiler-backend-string-contains? asm "make_array_len_ok"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-region-source) : String
  "(define (main) : i64
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
              ".L_tl_region_reset_drop_newer_unmap:\n")
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
  "(extern tl_process_output : (-> i64 i64))
(define (main) : i64 (tl_process_output 0))")

(define (compiler-backend-process-output-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-process-output-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "tl_process_output:\n")
        (and
          (compiler-backend-string-contains? asm "    call tl_process_output\n")
          (and
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_process_output\n"))
            (and
              (not
                (compiler-backend-string-contains? asm "_tl_tl_process_output"))
              (and
                (compiler-backend-string-contains?
                  asm
                  ".L_tl_process_read_all:\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    ".L_tl_process_exec_marker:")
                  (and
                    (compiler-backend-string-contains? asm ".L_tl_envp:\n")
                    (and
                      (compiler-backend-string-contains?
                        asm
                        "    movq $57, %rax\n")
                      (and
                        (compiler-backend-string-contains?
                          asm
                          "    movq $59, %rax\n")
                        (and
                          (compiler-backend-string-contains?
                            asm
                            "    movq $61, %rax\n")
                          (and
                            (compiler-backend-string-contains?
                              asm
                              "    movq $319, %rax\n")
                            (and
                              (compiler-backend-string-contains?
                                asm
                                "    movq $293, %rax\n")
                              (compiler-backend-string-contains?
                                asm
                                "tl_alloc:\n")))))))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-process-output-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-process-output-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "tl_process_output:\n")
        (and
          (compiler-backend-string-contains?
            asm
            "process: runtime execution is not supported on this target")
          (and
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_process_output\n"))
            (and
              (not
                (compiler-backend-string-contains? asm "_tl_tl_process_output"))
              (and
                (not (compiler-backend-string-contains? asm "    syscall"))
                (and
                  (not (compiler-backend-string-contains? asm ".L_tl_envp:\n"))
                  (compiler-backend-string-contains? asm "tl_alloc:\n")))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-env-runtime-source) : String
  "(define (main) : i64
  (if (env-var-exists? \"TYPELISP_TEST_ENV\")
    (string-length (env-var-value \"TYPELISP_TEST_ENV\"))
    (string-length (env-path-separator))))")

(define (compiler-backend-env-runtime-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-env-runtime-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "_tl_env_var_exists_question:\n")
        (and
          (compiler-backend-string-contains?
            asm
            "    call _tl_env_var_exists_question\n")
          (and
            (compiler-backend-string-contains? asm "_tl_env_var_value:\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    call _tl_env_var_value\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "_tl_env_path_separator:\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    call _tl_env_path_separator\n")
                  (and
                    (compiler-backend-string-contains? asm ".L_tl_envp:\n")
                    (and
                      (compiler-backend-string-contains?
                        asm
                        "    movq %rax, .L_tl_envp(%rip)\n")
                      (compiler-backend-string-contains? asm "tl_alloc:\n")))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-env-runtime-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-env-runtime-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "_tl_env_var_exists_question:\n")
        (and
          (compiler-backend-string-contains? asm "_tl_env_var_value:\n")
          (and
            (compiler-backend-string-contains? asm "_tl_env_path_separator:\n")
            (and
              (compiler-backend-string-contains? asm "    .extern getenv\n")
              (and
                (compiler-backend-string-contains? asm "    .extern strlen\n")
                (and
                  (compiler-backend-string-contains? asm "    call getenv\n")
                  (and
                    (compiler-backend-string-contains? asm "    call strlen\n")
                    (and
                      (compiler-backend-string-contains? asm "    movb $59,")
                      (not
                        (compiler-backend-string-contains? asm ".L_tl_envp:\n"))))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-sdk-registry-runtime-source) : String
  "(extern tl_windows_sdk_registry_install : (-> i64))
(define (main) : i64 (tl_windows_sdk_registry_install))")

(define (compiler-backend-windows-sdk-registry-runtime-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-windows-sdk-registry-runtime-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          "tl_windows_sdk_registry_install:")
        (and
          (compiler-backend-string-contains?
            asm
            ".L_tl_windows_registry_unsupported_msg:")
          (and
            (compiler-backend-string-contains?
              asm
              "    call tl_windows_sdk_registry_install")
            (and
              (not
                (compiler-backend-string-contains?
                  asm
                  ".extern tl_windows_sdk_registry_install"))
              (not
                (compiler-backend-string-contains?
                  asm
                  "_tl_tl_windows_sdk_registry_install"))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-append-file-status-ok?) : bool
  (match (compiler-backend-emit-source
    "(define (main) : i64 (append-file-status \"out.txt\" \"x\"))")
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".L_tl_append_file_status:\n")
        (and
          (compiler-backend-string-contains? asm "    movq $1089, %rdx\n")
          (not
            (compiler-backend-string-contains?
              asm
              ".extern .L_tl_append_file_status\n"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-fs-runtime-source) : String
  "(define (main) : i64
  (+ (fs-process-id)
    (+ (fs-mkdir-status \"target/typelisp-fs\")
      (+ (fs-remove-file-status \"target/typelisp-fs/artifact.o\")
        (+ (fs-remove-dir-status \"target/typelisp-fs\")
          (fs-rename-status
            \"target/typelisp-fs/from name\"
            \"target/typelisp-fs/to name\"))))))")

(define (compiler-backend-fs-runtime-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-fs-runtime-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fs_remove_file_status:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fs_remove_dir_status:\n")
          (compiler-backend-string-contains? asm ".L_tl_fs_rename_status:\n")
          (compiler-backend-string-contains? asm ".L_tl_fs_process_id:\n")
          (compiler-backend-string-contains? asm "    movq $83, %rax\n")
          (compiler-backend-string-contains? asm "    movq $87, %rax\n")
          (compiler-backend-string-contains? asm "    movq $84, %rax\n"))
        (and
          (compiler-backend-string-contains? asm "    movq $82, %rax\n")
          (and
            (compiler-backend-string-contains? asm "    movq $39, %rax\n")
            (and
              (not
                (compiler-backend-string-contains? asm "    .extern _mkdir\n"))
              (not
                (compiler-backend-string-contains?
                  asm
                  ".extern .L_tl_fs_rename_status\n"))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-fs-runtime-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-fs-runtime-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fs_remove_file_status:\n")
          (compiler-backend-string-contains?
            asm
            ".L_tl_fs_remove_dir_status:\n")
          (compiler-backend-string-contains? asm ".L_tl_fs_rename_status:\n")
          (compiler-backend-string-contains? asm ".L_tl_fs_process_id:\n")
          (compiler-backend-string-contains? asm "    call _mkdir\n")
          (compiler-backend-string-contains? asm "    call _unlink\n")
          (compiler-backend-string-contains? asm "    call _rmdir\n"))
        (and
          (compiler-backend-string-contains? asm "    call _errno\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    call GetCurrentProcessId\n")
            (and
              (backend-and4
                (compiler-backend-string-contains? asm "    .extern _mkdir\n")
                (compiler-backend-string-contains? asm "    .extern _unlink\n")
                (compiler-backend-string-contains? asm "    .extern _rmdir\n")
                (compiler-backend-string-contains?
                  asm
                  "    .extern GetCurrentProcessId\n"))
              (and
                (compiler-backend-string-contains? asm "    movq $38, %rax\n")
                (not (compiler-backend-string-contains? asm "    syscall")))))))]
    [(ErrCompilerBackend _) false]))

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
        (compiler-backend-string-contains? asm "_tl_classify:\n")
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
        (and
          (compiler-backend-string-contains? asm "    movsd %xmm0, ")
          (and
            (compiler-backend-string-contains? asm "    movsd %xmm1, ")
            (and
              (compiler-backend-string-contains? asm "    addsd %xmm1, %xmm0\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    subsd %xmm1, %xmm0\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    ucomisd %xmm1, %xmm0\n")
                  (compiler-backend-string-contains? asm "    setb %al\n")))))))]
    [(ErrCompilerBackend _) false]))

;; Backend-owned replacement for the Rust bool logic codegen checks (#1044):
;; `and`/`or` arrive from the lowerer as branches, not eager bytewise ops, and
;; bool equality still uses the comparison/setcc path.
(define (compiler-backend-bool-and-source) : String
  "(define (f [a : bool] [b : bool]) : bool (and a b))")

(define (compiler-backend-bool-or-source) : String
  "(define (f [a : bool] [b : bool]) : bool (or a b))")

(define (compiler-backend-bool-eq-source) : String
  "(define (f [a : bool] [b : bool]) : bool (= a b))")

(define (compiler-backend-todo-marker) : String
  (string-append "# " "TODO"))

(define (compiler-backend-bool-control-flow-ok?) : bool
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
      (compiler-backend-todo-marker))))

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
          (compiler-backend-string-contains? asm "    xorq %rbx, %rax\n")
          (compiler-backend-string-contains? asm "    xorq %rcx, %rax\n"))
        (compiler-backend-string-contains? asm "    shlq %cl, %rax\n")
        (compiler-backend-string-contains? asm "    sarq %cl, %rax\n")
        (not (compiler-backend-string-contains? asm "    orq "))
        (not (compiler-backend-string-contains? asm "    addq %rbx, %rax\n"))
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker)))
        true
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-scalar-div-mod-source) : String
  "(define (div64 [a : i64] [b : i64]) : i64 (/ a b))
(define (mod64 [a : i64] [b : i64]) : i64 (% a b))
(define (main) : i64
  (+ (div64 42 6) (mod64 22 7)))")

(define (compiler-backend-scalar-div-mod-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-scalar-div-mod-source))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm "    cqto\n")
        (compiler-backend-string-contains? asm "    idivq %rbx\n")
        (compiler-backend-string-contains? asm "    movq %rdx, %rax\n")
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker)))
        true
        true
        true
        true)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-checked-trap-entry-block) : CompilerIrBlock
  (IrBlock
    "entry"
    (IrInstrCons
      (IrInstrBinOp 0 (IrBinEq) (IrValueI64 0) (IrValueI64 0) (AstTyI64))
      (IrInstrCons
        (IrInstrBranch (IrValueVar 0) "div_trap" "div_ok")
        IrInstrNil))))

(define (compiler-backend-checked-trap-div-block) : CompilerIrBlock
  (IrBlock
    "div_trap"
    (IrInstrCons
      (IrInstrCall 1 "tl_div_abort" IrValueNil (AstTyUnit))
      (IrInstrCons (IrInstrJump "div_ok") IrInstrNil))))

(define (compiler-backend-checked-trap-div-ok-block) : CompilerIrBlock
  (IrBlock
    "div_ok"
    (IrInstrCons
      (IrInstrBinOp 2 (IrBinDiv) (IrValueI64 42) (IrValueI64 6) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 3 (IrBinMod) (IrValueI64 22) (IrValueI64 7) (AstTyI64))
        (IrInstrCons
          (IrInstrBinOp 4 (IrBinEq) (IrValueI64 64) (IrValueI64 64) (AstTyI64))
          (IrInstrCons
            (IrInstrBranch (IrValueVar 4) "shift_trap" "shift_ok")
            IrInstrNil))))))

(define (compiler-backend-checked-trap-shift-block) : CompilerIrBlock
  (IrBlock
    "shift_trap"
    (IrInstrCons
      (IrInstrCall 5 "tl_shift_abort" IrValueNil (AstTyUnit))
      (IrInstrCons (IrInstrJump "shift_ok") IrInstrNil))))

(define (compiler-backend-checked-trap-shift-ok-block) : CompilerIrBlock
  (IrBlock
    "shift_ok"
    (IrInstrCons
      (IrInstrBinOp 6 (IrBinShl) (IrValueI64 1) (IrValueI64 2) (AstTyI64))
      (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 6))) IrInstrNil))))

(define (compiler-backend-checked-trap-blocks) : CompilerIrBlockList
  (IrBlockCons
    (compiler-backend-checked-trap-entry-block)
    (IrBlockCons
      (compiler-backend-checked-trap-div-block)
      (IrBlockCons
        (compiler-backend-checked-trap-div-ok-block)
        (IrBlockCons
          (compiler-backend-checked-trap-shift-block)
          (IrBlockCons
            (compiler-backend-checked-trap-shift-ok-block)
            IrBlockNil))))))

(define (compiler-backend-checked-trap-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
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
        (compiler-backend-string-contains? asm ".Lmain_div_trap:\n")
        (compiler-backend-string-contains? asm ".Lmain_shift_trap:\n")
        (compiler-backend-string-contains? asm "    call tl_div_abort\n")
        (compiler-backend-string-contains? asm "    call tl_shift_abort\n"))]
    [helper-shapes : bool
      (backend-and8
        (compiler-backend-string-contains? asm ".globl tl_div_abort\n")
        (compiler-backend-string-contains? asm "tl_div_abort:\n")
        (compiler-backend-string-contains? asm ".L_tl_div_msg:")
        (compiler-backend-string-contains? asm "movq $135, %rdi\n")
        (compiler-backend-string-contains? asm ".globl tl_shift_abort\n")
        (compiler-backend-string-contains? asm "tl_shift_abort:\n")
        (compiler-backend-string-contains? asm ".L_tl_shift_msg:")
        (compiler-backend-string-contains? asm "movq $129, %rdi\n"))]
    [op-shapes : bool
      (backend-and4
        (compiler-backend-string-contains? asm "    idivq %rbx\n")
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
    (and trap-branches (and helper-shapes (and op-shapes no-externs)))))

(define (compiler-backend-checked-trap-emit-shape-ok?) : bool
  (match (compiler-backend-emit-program (compiler-backend-checked-trap-program))
    [(OkCompilerBackend asm) (compiler-backend-checked-trap-asm-shape-ok? asm)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-narrow-binop-types
  [lhs-ty : AstType]
  [rhs-ty : AstType]) : CompilerRegVarTypeList
  (CompilerRegVarTypeCons
    (CompilerRegVarType 0 lhs-ty)
    (CompilerRegVarTypeCons (CompilerRegVarType 1 rhs-ty) CompilerRegVarTypeNil)))

(define (compiler-backend-narrow-binop-shape?
  [op : CompilerIrBinOp]
  [lhs-ty : AstType]
  [rhs-ty : AstType]
  [result-ty : AstType]
  [needle : String]
  [bad : String]) : bool
  (match (compiler-backend-emit-binop
    (compiler-backend-narrow-binop-types lhs-ty rhs-ty)
    CompilerRegAssignmentNil
    2
    op
    (IrValueVar 0)
    (IrValueVar 1)
    result-ty)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm needle)
        (and
          (if (string-eq bad "")
            true
            (not (compiler-backend-string-contains? asm bad)))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))))]
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
        "    addl %ebx, %eax\n"
        "    addq %rbx, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinMul)
        (AstTyI32)
        (AstTyI32)
        (AstTyI32)
        "    imull %ebx, %eax\n"
        "    imulq %rbx, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinDiv)
        (AstTyI32)
        (AstTyI32)
        (AstTyI32)
        "    cdq\n    idivl %ebx\n"
        "    idivq %rbx\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinAdd)
        (AstTyI8)
        (AstTyI8)
        (AstTyI8)
        "    addb %bl, %al\n"
        "    addq %rbx, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinSub)
        (AstTyI8)
        (AstTyI8)
        (AstTyI8)
        "    subb %bl, %al\n"
        "    subq %rbx, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinLt)
        (AstTyI8)
        (AstTyI8)
        (AstTyBool)
        "    cmpb %bl, %al\n    setl %al\n"
        "    cmpq %rbx, %rax\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinMod)
        (AstTyI8)
        (AstTyI8)
        (AstTyI8)
        "    cbw\n    idivb %bl\n    movb %ah, %al\n"
        "    idivq %rbx\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinBitAnd)
        (AstTyI16)
        (AstTyI16)
        (AstTyI16)
        "    andw %bx, %ax\n"
        "    andq %rbx, %rax\n"))
    (backend-and4
      (compiler-backend-narrow-binop-shape?
        (IrBinDiv)
        (AstTyI16)
        (AstTyI16)
        (AstTyI16)
        "    cwd\n    idivw %bx\n"
        "    idivq %rbx\n")
      (compiler-backend-narrow-binop-shape?
        (IrBinMod)
        (AstTyU8)
        (AstTyU8)
        (AstTyU8)
        "    andw $0x00ff, %ax\n    divb %bl\n    movb %ah, %al\n"
        "    idivq %rbx\n")
      (and
        (compiler-backend-narrow-binop-shape?
          (IrBinShr)
          (AstTyI8)
          (AstTyU8)
          (AstTyI8)
          "    movq %rbx, %rcx\n    sarb %cl, %al\n"
          "    sarq %cl, %rax\n")
        (compiler-backend-narrow-binop-shape?
          (IrBinShr)
          (AstTyU8)
          (AstTyU8)
          (AstTyU8)
          "    movq %rbx, %rcx\n    shrb %cl, %al\n"
          "    sarb %cl, %al\n"))
      (and
        (compiler-backend-narrow-binop-shape?
          (IrBinShl)
          (AstTyU8)
          (AstTyU8)
          (AstTyU8)
          "    movq %rbx, %rcx\n    shlb %cl, %al\n"
          "    shlq %cl, %rax\n")
        (compiler-backend-narrow-binop-shape?
          (IrBinLt)
          (AstTyU8)
          (AstTyU8)
          (AstTyBool)
          "    cmpb %bl, %al\n    setb %al\n"
          "    setl %al\n")))))

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
        (compiler-backend-string-contains? asm "    call _tl_half\n")
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
  (sum5 x 2.0 3.0 4.0 5.0))

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
          (compiler-backend-string-contains? asm "    subq $112, %rsp\n")
          (compiler-backend-string-contains?
            asm
            "    movsd -48(%rbp), %xmm15\n")
          (compiler-backend-string-contains? asm "    movsd %xmm15, 32(%rsp)\n")
          (compiler-backend-string-contains? asm "    movsd 48(%rbp), %xmm0\n"))
        (and
          (compiler-backend-string-contains?
            asm
            "    call _tl_call5\n    movsd %xmm0, -16(%rbp)\n")
          (and
            (compiler-backend-string-contains? asm "    call _tl_sum5\n")
            (and
              (not (compiler-backend-string-contains? asm "too many call args"))
              (and
                (not (compiler-backend-string-contains? asm "    syscall"))
                (not
                  (compiler-backend-string-contains?
                    asm
                    (compiler-backend-todo-marker))))))))]
    [(ErrCompilerBackend _) false]))

;; #750: a SysV call with seven integer args no longer rejects as "too many
;; call args". The 7th arg spills: 16-byte call space is reserved, the spilled
;; value is staged through %r11 and stored at 0(%rsp), and `add8` reads its
;; stack-passed params back from 16(%rbp)/24(%rbp).
(define (compiler-backend-stack-int-args-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-stack-int-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (and
          (compiler-backend-string-contains? asm "    subq $16, %rsp\n")
          (and
            (compiler-backend-string-contains? asm "    movq %r11, 0(%rsp)\n")
            (and
              (compiler-backend-string-contains? asm "    addq $16, %rsp\n")
              (and
                (compiler-backend-string-contains? asm "    call _tl_add8\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    movq 16(%rbp), %rax\n")
                  (compiler-backend-string-contains?
                    asm
                    "    movq 24(%rbp), %rax\n")))))))]
    [(ErrCompilerBackend _) false]))

;; #750: a SysV call with ten f64 args uses xmm0..xmm7 then spills two on the
;; stack through %xmm15; the callee reads them back via movsd from the incoming
;; stack slots.
(define (compiler-backend-stack-f64-args-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-stack-f64-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (and
          (compiler-backend-string-contains? asm "    subq $16, %rsp\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    movsd %xmm15, 0(%rsp)\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    movsd %xmm15, 8(%rsp)\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    movsd 16(%rbp), %xmm0\n")
                (compiler-backend-string-contains?
                  asm
                  "    movsd 24(%rbp), %xmm0\n"))))))]
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
        (and
          (compiler-backend-string-contains? asm "    movq %r11, 0(%rsp)\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    movsd %xmm15, 8(%rsp)\n")
            (compiler-backend-string-contains? asm "    call _tl_mix\n"))))]
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
        (and
          (not (compiler-backend-string-contains? asm "    addq $64, %rsp\n"))
          (and
            (compiler-backend-string-contains? asm "    movq %r11, 32(%rsp)\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    movq %r11, 56(%rsp)\n")
              (compiler-backend-string-contains?
                asm
                "    movq 48(%rbp), %rax\n")))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-stack-args-ok?) : bool
  (and
    (compiler-backend-stack-int-args-ok?)
    (and
      (compiler-backend-stack-f64-args-ok?)
      (and
        (compiler-backend-stack-mixed-args-ok?)
        (compiler-backend-stack-windows-args-ok?)))))

(define (compiler-backend-raw-pointer-fixture-shape-ok?) : bool
  (match (compiler-backend-raw-pointer-fixture-emit (BackendTargetLinux))
    [(OkCompilerBackend asm)
      (backend-and8
        (compiler-backend-string-contains? asm "_tl_write_i64:")
        (compiler-backend-string-contains? asm "_tl_read_i64:")
        (compiler-backend-string-contains? asm "    call _tl_write_i64\n")
        (compiler-backend-string-contains? asm "    call _tl_read_i64\n")
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
        (compiler-backend-string-contains?
          asm
          "    movq $8, %rdi\n    call tl_alloc\n")
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
          (compiler-backend-string-contains?
            asm
            "    movq $16, %rdi\n    call tl_alloc\n")
          (compiler-backend-string-contains? asm "    movq $1, %rax\n")
          (compiler-backend-string-contains? asm "    movb %al, (%r10)\n")
          (compiler-backend-string-contains? asm "    movq $42, %rax\n")
          (compiler-backend-string-contains? asm "    movq %rax, 8(%r10)\n")
          (compiler-backend-string-contains? asm "    movq 8(%r10), %rax\n")
          true
          true)
        (not
          (compiler-backend-string-contains? asm (compiler-backend-todo-marker))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-self-test) : i64
  (if (and
    (backend-and8
      (compiler-backend-target-model-ok? (compiler-backend-smoke-source))
      (compiler-backend-array-access-asm-ok?)
      (compiler-backend-make-array-ok?)
      (compiler-backend-source-ok? (compiler-backend-smoke-source))
      (compiler-backend-deterministic-ok? (compiler-backend-smoke-source))
      (compiler-backend-string-ok?)
      (and
        (compiler-backend-memory-op-ok?)
        (compiler-backend-numeric-cast-shape-ok?))
      (compiler-backend-aggregate-ok?))
    (and
      (backend-and8
        (compiler-backend-literal-payload-ok?)
        (compiler-backend-enum-match-ok?)
        (compiler-backend-regalloc-ok?)
        (compiler-backend-peephole-ok?)
        (compiler-backend-phi-parallel-copy-ok?)
        (compiler-backend-f64-ok?)
        (compiler-backend-bool-control-flow-ok?)
        (compiler-backend-stack-args-ok?))
      (and
        (backend-and8
          (compiler-backend-instr-diagnostics-ok?)
          (compiler-backend-optimizer-rewrite-diagnostic-ok?)
          (compiler-backend-runtime-helper-asm-ok?)
          (compiler-backend-alloc-runtime-arena-ok?)
          (compiler-backend-region-ok?)
          (compiler-backend-process-output-ok?)
          (compiler-backend-windows-process-output-ok?)
          (compiler-backend-append-file-status-ok?))
        (and
          (compiler-backend-fs-runtime-ok?)
          (and
            (compiler-backend-windows-fs-runtime-ok?)
            (and
              (backend-and8
                (compiler-backend-user-helper-name-ok?)
                (compiler-backend-file-handle-open-close-runtime-ok?)
                (and
                  (compiler-backend-string-runtime-ok?)
                  (compiler-backend-print-runtime-ok?))
                (compiler-backend-env-runtime-ok?)
                (compiler-backend-expanded-scalar-regs-ok?)
                (compiler-backend-regalloc-f64-ok?)
                (compiler-backend-runtime-coexist-ok?)
                (compiler-backend-module-symbol-ok?))
              (and
                (and
                  (compiler-backend-windows-env-runtime-ok?)
                  (compiler-backend-extern-metadata-symbol-ok?))
                (and
                  (backend-and4
                    (compiler-backend-string-ref-shape-ok?)
                    (compiler-backend-fixed-array-shape-ok?)
                    (compiler-backend-raw-pointer-fixture-shape-ok?)
                    (compiler-backend-box-ok?))
                  (and
                    (compiler-backend-tuple-ok?)
                    (and
                      (compiler-backend-checked-trap-emit-shape-ok?)
                      (and
                        (compiler-backend-closure-emit-shape-ok?)
                        (and
                          (compiler-backend-avx2-vector-map-ok?)
                          (and
                            (compiler-backend-avx2-vector-reduce-ok?)
                            (and
                              (compiler-backend-avx512-vector-map-ok?)
                              (backend-and8
                                (compiler-backend-scalar-wide-ops-ok?)
                                (compiler-backend-scalar-div-mod-ok?)
                                (compiler-backend-narrow-scalar-instr-ok?)
                                (compiler-backend-f64-abi-ok?)
                                (compiler-backend-win64-f64-abi-ok?)
                                (compiler-backend-aggregate-storage-shape-ok?)
                                (compiler-backend-alloc-runtime-shape-ok?)
                                (compiler-backend-windows-sdk-registry-runtime-ok?))))))))))))))))
    42
    (begin
      (panic "backend: smoke output mismatch")
      0)))