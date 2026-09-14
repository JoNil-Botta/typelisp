(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_backend as backend)
(import compiler_abi as abi)
(import compiler_intern as intern)

(test
  register-reload-record-preserves-owner-transitions
  (let
    [input : String
      "    movq -24(%rbp), %rax
    cmpq $0, %rbx
    movq -24(%rbp), %r10
    movq -24(%rbp), %r11
    movq -24(%rbp), %r11
    movq $7, %rax
    movq -24(%rbp), %rdx
    call _tl_other
    movq -24(%rbp), %r9"]
    [expected : String
      "    movq -24(%rbp), %rax
    cmpq $0, %rbx
    movq %rax, %r10
    movq %rax, %r11
    movq $7, %rax
    movq %r10, %rdx
    call _tl_other
    movq -24(%rbp), %r9"]
    (unless
      (string.eq (backend.compiler-backend-peephole-asm input) expected)
      (io.panic "reload reuse changed owner transfer or call invalidation"))))

(test
  register-reload-record-matches-free-form-oracle
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new
        (intern.intern-compat-state-capture-active))]
    [stream : backend.CompilerBackendStreamState
      (backend.compiler-backend-state-stream-state state)]
    [source-id : i64 0]
    (while (< source-id 16)
      (begin
        (unless
          (or
            (= source-id abi.compiler-reg-id-rsp)
            (= source-id abi.compiler-reg-id-rbp))
          (let
            [destination-id : i64 0]
            (while (< destination-id 16)
              (begin
                (unless
                  (or
                    (= destination-id abi.compiler-reg-id-rsp)
                    (= destination-id abi.compiler-reg-id-rbp))
                  (let
                    [newline-mode : i64 0]
                    (while (< newline-mode 2)
                      (let
                        [source : String
                          (abi.compiler-abi-register-spelling source-id)]
                        [destination : String
                          (abi.compiler-abi-register-spelling destination-id)]
                        [newline? : bool (= newline-mode 1)]
                        [load : backend.CompilerBackendPeepholeLine
                          (backend.compiler-backend-peephole-owned-line
                            state
                            stream
                            (str_cat.str-cat
                              "    movq -24(%rbp), "
                              (backend.compiler-backend-global-shared-view
                                destination))
                            newline?)]
                        [direct-record : backend.CompilerBackendPeepholeLineRecord
                          (backend.compiler-backend-peephole-reused-register-record
                            (backend.compiler-backend-global-shared-view source)
                            load)]
                        [parsed : backend.CompilerBackendPeepholeLine
                          (backend.compiler-backend-peephole-owned-line
                            state
                            stream
                            (str_cat.str-cat
                              "    movq "
                              source
                              ", "
                              destination)
                            newline?)]
                        [parsed-record : backend.CompilerBackendPeepholeLineRecord
                          (backend.compiler-backend-peephole-line-record
                            (backend.compiler-backend-global-shared-view parsed))]
                        (begin
                          (unless
                            (and
                              (string.eq direct-record.src parsed-record.src)
                              (= direct-record.span parsed-record.span)
                              (= direct-record.meta parsed-record.meta)
                              (= direct-record.cand parsed-record.cand)
                              (= direct-record.epilogue parsed-record.epilogue)
                              (= direct-record.value parsed-record.value))
                            (io.panic
                              "register reload metadata differs from parsed assembly"))
                          (set! newline-mode (+ newline-mode 1)))))))
                (set! destination-id (+ destination-id 1))))))
        (set! source-id (+ source-id 1))))))