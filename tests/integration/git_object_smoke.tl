(import git_object_tests as fixtures)

(define (main) : i64
  (if (and
    (fixtures.git-object-test-tree?)
    (fixtures.git-object-test-boundaries?)
    (fixtures.git-object-test-tree-scaling?)
    (fixtures.git-object-test-tree-prefixes?)
    (fixtures.git-object-test-tree-name-sequences?)
    (fixtures.git-object-test-tree-separated-duplicates? (Sha1))
    (fixtures.git-object-test-tree-separated-duplicates? (Sha256)))
    42
    1))