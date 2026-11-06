;# Internal best-effort reclamation of retired crypto stack frames.
;#
;# These fixed, target-selected windows are checked against emitted frame
;# intervals at opt1 and opt2. They are not a language erasure guarantee.
;# Registers, caches, dumps and fatal exits are outside this mechanism.
;: Volatile-wipe complete target-sized chunks. The caller owns the entire region and chunks is positive.
;: Unrolling amortizes the scalar wipe ABI/loop cost without compiler changes.
(unsafe
  (define (wipe-chunks! [data : (MutPtr u64)] [chunks : i64]) : unit
    (let
      [index : i64 0]
      (while true
        (let
          [chunk : (MutPtr u64)
            (unsafe
              (ptr-offset data (* index (cfg windows 102 92))))]
          (unsafe
            (volatile-store! chunk (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 1) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 2) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 3) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 4) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 5) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 6) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 7) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 8) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 9) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 10) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 11) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 12) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 13) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 14) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 15) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 16) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 17) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 18) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 19) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 20) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 21) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 22) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 23) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 24) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 25) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 26) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 27) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 28) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 29) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 30) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 31) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 32) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 33) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 34) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 35) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 36) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 37) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 38) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 39) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 40) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 41) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 42) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 43) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 44) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 45) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 46) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 47) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 48) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 49) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 50) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 51) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 52) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 53) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 54) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 55) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 56) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 57) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 58) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 59) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 60) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 61) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 62) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 63) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 64) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 65) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 66) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 67) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 68) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 69) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 70) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 71) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 72) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 73) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 74) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 75) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 76) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 77) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 78) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 79) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 80) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 81) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 82) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 83) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 84) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 85) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 86) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 87) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 88) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 89) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 90) (cast 0 : u64))
            (volatile-store! (ptr-offset chunk 91) (cast 0 : u64))
            (cfg
              windows
              (begin
                (volatile-store! (ptr-offset chunk 92) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 93) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 94) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 95) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 96) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 97) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 98) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 99) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 100) (cast 0 : u64))
                (volatile-store! (ptr-offset chunk 101) (cast 0 : u64)))
              unit)))
        (set! index (+ index 1))
        (when (= index chunks) (break))))))

;: Public block callers reclaim the retired AES arithmetic-helper frames.
(define (block!) : unit
  (cfg
    windows
    (let
      [scratch : (Array u64 102) (make-array u64 102)]
      (unsafe
        (wipe-chunks! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 1)))
    (let
      [scratch : (Array u64 92) (make-array u64 92)]
      (unsafe
        (wipe-chunks! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 1)))))

;: Consuming AES constructors reclaim their entire retired schedule chain.
(define (setup!) : unit
  (cfg
    windows
    (let
      [scratch : (Array u64 408) (make-array u64 408)]
      (unsafe
        (wipe-chunks! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 4)))
    (let
      [scratch : (Array u64 368) (make-array u64 368)]
      (unsafe
        (wipe-chunks! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 4)))))

;: GCM reclaims its retired setup/seal/open tree once, on every result path.
(define (tree!) : unit
  (cfg
    windows
    (let
      [scratch : (Array u64 816) (make-array u64 816)]
      (unsafe
        (wipe-chunks! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 8)))
    (let
      [scratch : (Array u64 736) (make-array u64 736)]
      (unsafe
        (wipe-chunks! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 8)))))