#!/bin/zsh
set -u
here=${0:A:h}; root=${here:h}
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
# units.swift (not named logic.swift: on a case-insensitive disk its object file would clash with ggd/Logic.swift)
sources=($here/units.swift)
[[ ! -f $root/app/Model.swift ]] || sources+=($root/app/Model.swift)
[[ ! -f $root/ggd/Logic.swift ]] || sources+=($root/ggd/Logic.swift)
swiftc -target x86_64-apple-macos26.0 -parse-as-library -module-cache-path "$tmp/cache" -o "$tmp/logic" "${sources[@]}" \
    && "$tmp/logic" || fail=1
if [[ -f $here/ggd.sh ]]; then
    swiftc -target x86_64-apple-macos26.0 -O -module-cache-path "$tmp/cache" -o "$tmp/ggd" $root/ggd/*.swift \
        && /bin/zsh "$here/ggd.sh" "$tmp/ggd" || fail=1
fi
if [[ -f $here/check.sh ]]; then
    /bin/zsh "$here/check.sh" || fail=1
fi
for f in uninstall.sh postinstall.sh; do
    [[ ! -f $here/$f ]] || /bin/zsh "$here/$f" || fail=1
done
[[ $fail == 0 ]] && print 'TOTAL: all passed' || print 'TOTAL: some failed'
exit $fail
