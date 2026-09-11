(import stdlib.crypto_sha1_git)

(define (main) : i64
  (let
    [state : crypto_sha1_git.GitSha1State (crypto_sha1_git.new)]
    (begin
      (crypto_sha1_git.update-from-pointer!
        (&mut state)
        (ptr-null : (Ptr u8))
        0)
      42)))