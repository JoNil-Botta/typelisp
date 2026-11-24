(import process_syscall_shadow_other.my-argc as program-argc)
(import process_syscall_shadow_other.my-argv as program-argv)
(import process_syscall_shadow_other.my-envp as program-envp)
(import process_syscall_shadow_other.my-syscall as syscall)

(define (run-selected) : i64
  (if (and
    (= (program-argc) 101)
    (= (program-argv 5) 107)
    (= (program-envp) 103)
    (= (syscall 19 23) 42))
    42
    1))