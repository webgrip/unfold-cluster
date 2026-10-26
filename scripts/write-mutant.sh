#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: write-mutant.sh <source> <from> <to> <mutant>

Writes <mutant>: a copy of <source> with the first occurrence of the literal
text <from> replaced by the literal text <to>, and marks it executable.
<mutant> may be <source> itself. When <source> does not contain <from> it
fails and leaves no <mutant> behind, so a mutation test can never run a
mutant that was not written, nor a stale one from an earlier case.

Needs node, which every CI image has for actions/checkout."

[ "$#" -eq 4 ] || { echo "${usage}" >&2; exit 2; }

node -e '
  const fs = require("fs");
  const path = require("path");
  const [source, from, to, mutant] = process.argv.slice(1);
  const text = fs.readFileSync(source, "utf8");
  const at = from === "" ? -1 : text.indexOf(from);
  if (at < 0) {
    if (path.resolve(mutant) !== path.resolve(source)) fs.rmSync(mutant, { force: true });
    process.stderr.write(`${source} does not contain the text to mutate\n`);
    process.exit(1);
  }
  fs.writeFileSync(mutant, text.slice(0, at) + to + text.slice(at + from.length));
  fs.chmodSync(mutant, 0o755);
' "$@"
