;; Unshadowed process-entry and syscall builtins inside a named module.
(define (real-builtins-ok?) : bool
  (let
    [argc : i64 (program-argc)]
    [argv-ok : bool
      (unsafe
        (not (ptr-null? (program-argv))))]
    [envp-ok : bool
      (cfg
        linux
        (unsafe
          (not (ptr-null? (program-envp))))
        (let
          [_envp : (Ptr (Ptr u8))
            (unsafe
              (program-envp))]
          true))]
    [syscall-ok : bool
      (cfg
        linux
        (>
          (unsafe
            (syscall 39))
          0)
        true)]
    (and (>= argc 1) argv-ok envp-ok syscall-ok)))