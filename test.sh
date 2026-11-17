#!/bin/zsh
# Runs all tests. Usage: ./test.sh [python-test-pattern]
set -u
cd "${0:A:h}"
rc=0
/usr/bin/python3 -m unittest discover -s cli/tests -p "${1:-test_*.py}" -t cli/tests 2>&1 || rc=1
if [[ -z "${1:-}" && -d shell/tests ]]; then
  for t in shell/tests/test_*.zsh; do zsh -f "$t" || rc=1; done
fi
exit $rc
