;; compiler_allocation_profile.tl - Opt-in compiler arena ownership telemetry.
;;
;; This profiler deliberately reads the existing arena headers only when a
;; compile request enables it. It does not add accounting to `tl_alloc` or the
;; inline bump-allocation fast paths, so ordinary compiles keep their allocator
;; instruction stream unchanged.
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)

(defstruct CompilerAllocationProfileStats
  (root i64)
  (used i64)
  (committed i64)
  (reserved i64)
  (segments i64))

(define compiler-allocation-profile-active : bool
  false)
(define compiler-allocation-profile-output-arena : i64
  0)

(define (compiler-allocation-profile-enabled?) : bool
  compiler-allocation-profile-active)

(define (compiler-allocation-profile-word [address : i64] [word : i64]) : i64
  (if (= address 0)
    0
    (unsafe
      (ptr-read (ptr-offset (int->ptr address : (Ptr i64)) word)))))

(define (compiler-allocation-profile-nonnegative [value : i64]) : i64
  (if (< value 0)
    0
    value))

(define (compiler-allocation-profile-root [arena-handle : i64]) : i64
  (if (= arena-handle 0)
    0
    (let
      [root : i64 (compiler-allocation-profile-word arena-handle 5)]
      (if (= root 0)
        arena-handle
        root))))

(define (compiler-allocation-profile-segment-used [segment : i64]) : i64
  (compiler-allocation-profile-nonnegative
    (-
      (compiler-allocation-profile-word segment 2)
      (compiler-allocation-profile-word segment 1))))

(define (compiler-allocation-profile-segment-committed [segment : i64]) : i64
  (compiler-allocation-profile-nonnegative
    (-
      (cfg
        windows
        ;; Windows reserves 64 MiB but commits in 4 MiB increments. The
        ;; committed-end pointer is the ninth arena-header word.
        (compiler-allocation-profile-word segment 8)
        ;; Linux maps the full segment; end is the fourth header word.
        (compiler-allocation-profile-word segment 3))
      segment)))

(define (compiler-allocation-profile-segment-reserved [segment : i64]) : i64
  (compiler-allocation-profile-nonnegative
    (- (compiler-allocation-profile-word segment 3) segment)))

(define (compiler-allocation-profile-add-segment
  [stats : CompilerAllocationProfileStats]
  [segment : i64]) : CompilerAllocationProfileStats
  (CompilerAllocationProfileStats
    (struct-get stats root)
    (+
      (struct-get stats used)
      (compiler-allocation-profile-segment-used segment))
    (+
      (struct-get stats committed)
      (compiler-allocation-profile-segment-committed segment))
    (+
      (struct-get stats reserved)
      (compiler-allocation-profile-segment-reserved segment))
    (+ (struct-get stats segments) 1)))

(define (compiler-allocation-profile-scan-active
  [head : i64]
  [initial : CompilerAllocationProfileStats]) : CompilerAllocationProfileStats
  (let
    [current : i64 head]
    [stats : CompilerAllocationProfileStats initial]
    (begin
      (while (not (= current 0))
        (begin
          (set! stats (compiler-allocation-profile-add-segment stats current))
          ;; Active arena segments form a newest-to-oldest chain through prev.
          (set! current (compiler-allocation-profile-word current 0))))
      stats)))

(define (compiler-allocation-profile-scan-retired
  [head : i64]
  [initial : CompilerAllocationProfileStats]) : CompilerAllocationProfileStats
  (let
    [current : i64 head]
    [stats : CompilerAllocationProfileStats initial]
    (begin
      (while (not (= current 0))
        (begin
          (set! stats (compiler-allocation-profile-add-segment stats current))
          ;; Rewound overflow segments form a separate chain through retired.
          (set! current (compiler-allocation-profile-word current 4))))
      stats)))

(define (compiler-allocation-profile-stats [arena-handle : i64]) : CompilerAllocationProfileStats
  (let
    [root : i64 (compiler-allocation-profile-root arena-handle)]
    (if (= root 0)
      (CompilerAllocationProfileStats 0 0 0 0 0)
      (let
        [current : i64 (compiler-allocation-profile-word root 7)]
        [active-head : i64
          (if (= current 0)
            root
            current)]
        [active : CompilerAllocationProfileStats
          (compiler-allocation-profile-scan-active
            active-head
            (CompilerAllocationProfileStats root 0 0 0 0))]
        (compiler-allocation-profile-scan-retired
          (compiler-allocation-profile-word root 4)
          active)))))

(define (compiler-allocation-profile-field [value : i64]) : String
  (string.append "|" (string.int->string value)))

(define (compiler-allocation-profile-line
  [phase : String]
  [owner : String]
  [stats : CompilerAllocationProfileStats]) : String
  (string.append
    "compile-allocation-profile|"
    (string.append
      phase
      (string.append
        "|"
        (string.append
          owner
          (string.append
            (compiler-allocation-profile-field (struct-get stats root))
            (string.append
              (compiler-allocation-profile-field (struct-get stats used))
              (string.append
                (compiler-allocation-profile-field (struct-get stats committed))
                (string.append
                  (compiler-allocation-profile-field
                    (struct-get stats reserved))
                  (string.append
                    (compiler-allocation-profile-field
                      (struct-get stats segments))
                    "\n"))))))))))

(define (compiler-allocation-profile-start!) : unit
  (if compiler-allocation-profile-active
    unit
    (begin
      (set! compiler-allocation-profile-output-arena (arena.tl_arena_make))
      (set! compiler-allocation-profile-active true)
      (io.print-error
        "compile-allocation-profile|phase|owner|arena_root|bump_bytes|committed_bytes|reserved_bytes|segments\n"))))

(define (compiler-allocation-profile-snapshot!
  [phase : String]
  [owner : String]
  [arena-handle : i64]) : unit
  (if (not compiler-allocation-profile-active)
    unit
    (let
      [stats : CompilerAllocationProfileStats
        (compiler-allocation-profile-stats arena-handle)]
      [home : i64 (arena.tl_arena_current)]
      (begin
        (unsafe
          (arena.tl_arena_set compiler-allocation-profile-output-arena))
        (let
          [mark : i64 (arena.tl_region_mark)]
          (begin
            (io.print-error
              (compiler-allocation-profile-line phase owner stats))
            (unsafe
              (arena.tl_region_reset mark))))
        (unsafe
          (arena.tl_arena_set home))))))

(define (compiler-allocation-profile-finish!) : unit
  (if (not compiler-allocation-profile-active)
    unit
    (let
      [scratch : i64 compiler-allocation-profile-output-arena]
      (begin
        (set! compiler-allocation-profile-active false)
        (set! compiler-allocation-profile-output-arena 0)
        (unsafe
          (arena.tl_arena_destroy scratch))))))