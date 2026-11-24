;; #9944: Selected imports shadow program-argc, program-argv, program-envp, and
;; syscall in a named module without affecting unshadowed modules.
(import process_syscall_shadow_dep as dep)
(import process_syscall_shadow_selected_dep as selected)

(define (main) : i64
  (unless (dep.real-builtins-ok?) (return 1))
  (selected.run-selected))