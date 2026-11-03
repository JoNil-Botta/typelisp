;; Hosted Linux stack oracle. Object emission goes through the production
;; admission/serialization boundary and has no assembly fallback.
(import build_run_core as build)
(import compiler_backend as backend)
(import compiler_intern as ci)
(import stdlib.vector)
(import (vector.vector String) as roots)
(import sym_i64_env as cfg)
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.str_cat)

(define (emit-tree [out : text_buf.TextBuf] [start : i64] [count : i64]) : text_buf.TextBuf
  (if (= count 1)
    (text_buf.append
      out
      (str_cat.str-cat
        "(bit-xor (+ n "
        (string.int->string (+ (* start 2) 1))
        ") (* n "
        (string.int->string (+ (* start 2) 3))
        "))"))
    (let
      [half : i64 (/ count 2)]
      [left : text_buf.TextBuf
        (emit-tree (text_buf.append out "(bit-xor ") start half)]
      [right : text_buf.TextBuf
        (emit-tree (text_buf.append left " ") (+ start half) (- count half))]
      (text_buf.append right ")"))))

(define (generate [count : i64] [path : String]) : unit
  (let
    [out : text_buf.TextBuf (text_buf.empty)]
    (text_buf.append!
      out
      "(define (dive [n : i64]) (:export-symbol \"stack_dive\") : i64\n  (let [child : i64 (dive (+ n 1))]\n    (+ child ")
    (if (= count 0)
      (text_buf.append! out "n")
      (set! out (emit-tree out 0 count)))
    (text_buf.append! out ")))\n(define (main) : i64 (+ (dive 1) 1))\n")
    (let
      [source : String (text_buf.render out)]
      (io.write-file path (byte_buf.str-as-bytes (& source))))))

(define (main) : i64
  (cond
    [(and
        (= (io.arg-count) 5)
        (or (string.eq (io.arg 1) "combo") (string.eq (io.arg 1) "combo-plain")))
      (let
        [entry : i64 (string.>int (io.arg 2))]
        [staging : i64 (string.>int (io.arg 3))]
        [raw : String
          (str_cat.str-cat
            ".text\n.globl combo\n.type combo,@function\ncombo:\n"
            (backend.compiler-backend-emit-stack-sub
              (backend.compiler-backend-target-policy-new
                (backend.CompilerBackendTarget.Linux))
              entry)
            (backend.compiler-backend-emit-call-space-sub staging)
            "    movb $0, (%rsp)\n    incq body_count(%rip)\n"
            (backend.compiler-backend-emit-call-space-add staging)
            (backend.compiler-backend-emit-call-space-add entry)
            "    ret\n.size combo, .-combo\n")]
        [assembly : String
          (if (string.eq (io.arg 1) "combo-plain")
            raw
            (backend.compiler-backend-peephole-asm-drop-fallthrough-target
              raw
              (backend.CompilerBackendTarget.Linux)))]
        (io.write-file (io.arg 4) (byte_buf.str-as-bytes (& assembly)))
        0)]
    [(and
        (= (io.arg-count) 5)
        (or (string.eq (io.arg 1) "plan") (string.eq (io.arg 1) "transient")))
      (let
        [size : i64 (string.>int (io.arg 2))]
        [entry? : bool (string.eq (io.arg 1) "plan")]
        [state
          (backend.compiler-backend-state-new
            (ci.intern-compat-state-capture-active))]
        [assembly : String
          (str_cat.str-cat
            ".text\n.globl probe\nprobe:\n    pushq %rbp\n    movq %rsp, %rbp\n"
            (if (>
              size
              (if entry?
                32768
                4096))
              (backend.compiler-backend-emit-stack-probe size)
              (backend.compiler-backend-emit-stack-sub
                (backend.compiler-backend-target-policy-new
                  (backend.CompilerBackendTarget.Linux))
                size)))]
        [bytes : String
          (if entry?
            (backend.compiler-backend-object-prologue-bytes
              (backend.CompilerBackendTarget.Linux)
              size)
            (str_cat.str-cat
              (backend.compiler-backend-object-prologue-bytes
                (backend.CompilerBackendTarget.Linux)
                0)
              (backend.compiler-backend-object-sub-rsp-bytes size state)))]
        (io.write-file (io.arg 3) (byte_buf.str-as-bytes (& assembly)))
        (io.write-file (io.arg 4) (byte_buf.str-as-bytes (& bytes)))
        (backend.compiler-backend-state-release-final-arenas! state)
        0)]
    [(and (= (io.arg-count) 4) (string.eq (io.arg 1) "generate"))
      (generate (string.>int (io.arg 2)) (io.arg 3))
      0]
    [(and (= (io.arg-count) 5) (string.eq (io.arg 1) "object"))
      (let
        [search : roots.Vec (roots.new)]
        [link-inputs : build.SourceToolLinkInputs
          (build.source-tool-link-inputs-empty)]
        (roots.push-ref! (&mut search) "stdlib")
        (roots.push-ref! (&mut search) "src")
        (match (build.source-tool-emit-object
          (io.arg 2)
          (build.SourceToolProgram.Source search (cfg.sym-i64-empty))
          (backend.CompilerBackendTarget.Linux)
          (string.>int (io.arg 3))
          (backend.CompilerBackendMode.Scalar)
          (& link-inputs))
          [(Ok bytes)
            (io.write-file (io.arg 4) (byte_buf.str-as-bytes (& bytes)))
            0]
          [(Err message)
            (io.eprintln "{}" message)
            1]))]
    [else
      (io.eprintln
        "usage: linux-stack-protection plan|transient SIZE ASM BYTES | combo ENTRY STAGING ASM | generate COUNT SOURCE | object SOURCE OPT OUTPUT")
      2]))