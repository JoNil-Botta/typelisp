(import stdlib.crypto_ghash_core as ghash)

(define (bad [state : (MutPtr u64)] [h : (Ptr u8)]) : unit
  (ghash.multiply! state h))