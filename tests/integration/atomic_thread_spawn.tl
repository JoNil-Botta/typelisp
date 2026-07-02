(import stdlib.arena)
(import stdlib.thread)

;; #33 forcing fixture: raw-thread spawn over an atomic arena.
;;
;; The spawned worker installs the shared atomic arena as its allocation
;; target, allocates in it, and returns 42; main spawns one worker, joins it,
;; and returns the joined value.
;;
;; This is the regression net for the rsp-rebase (FPO) unsoundness fixed in
;; #33: `thread-linux-spawn` issues a raw `clone` (syscall 56) that hands the
;; CHILD a fresh %rsp. The stage-1/FPO `compiler-backend-rsp-rebase` audit did
;; not recognise `syscall` as an rsp write, so it rebased the post-syscall
;; child arg-marshalling (`entry`/`arg`/`result-addr`/`started-addr`) to
;; N(%rsp) -- correct in the parent, but the child reads its own empty stack ->
;; garbage args to `thread-linux-child-main` -> SIGSEGV. The fix keeps %rbp for
;; any function containing a `syscall` (frame refs via %rbp survive `clone` in
;; both parent and child under CLONE_VM). Pre-fix HEAD SEGVs (exit 139); with
;; the fix this returns 42.

;: Worker body: switch to the shared atomic arena, allocate, restore, return 42.
(define (atomic-thread-worker [owner : i64]) : i64
  (let
    [home : i64 (arena.tl_arena_current)]
    (begin
      (unsafe
        (arena.tl_arena_set owner))
      (let
        [items : (Array i64) (make-array i64 4096)]
        (begin
          (array-set! items 0 21)
          (array-set! items 1 21)
          (let
            [sum : i64 (+ (array-ref items 0) (array-ref items 1))]
            (begin
              (unsafe
                (arena.tl_arena_set home))
              sum)))))))

;: Spawn one worker over `owner`, join it, and surface the joined value.
(define (atomic-thread-run [owner : i64]) : i64
  (let
    [spawn : thread.ThreadSpawnResult
      (thread.thread-spawn atomic-thread-worker owner)]
    (if (not (thread.thread-spawn-result-ok? spawn))
      2
      (let
        [worker : thread.Thread
          (thread.thread-spawn-result-thread-or spawn (thread.Thread 0 0 0))]
        (thread.thread-join-result-value-or (thread.thread-join worker) 3)))))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.arena-make-atomic)]
    [result : i64 (atomic-thread-run (arena.arena-raw-handle owner))]
    (begin
      (unsafe
        (arena.arena-destroy owner))
      result)))
