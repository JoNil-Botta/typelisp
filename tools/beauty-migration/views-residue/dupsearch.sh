#!/bin/sh
# usage: dupsearch.sh QUERY...: search issues (all states) for each query.
for q in "$@"; do
  echo "== $q"
  gh issue list --state all --search "$q" --limit 8 --json number,title,state --jq '.[] | "\(.number) \(.state) \(.title)"'
done
