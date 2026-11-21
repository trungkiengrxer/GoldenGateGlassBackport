#!/bin/zsh
set -u
here=${0:A:h}; check=${here:h}/pkg/check.sh
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
export GG_OSVERSION=25G72 GG_ARCH=x86_64 CSRUTIL=$tmp/csrutil NVRAM=$tmp/nvram
export SIP_STATUS='System Integrity Protection status: disabled.'
export BOOT_ARGS='amfi_get_out_of_my_way=1'
cat > "$CSRUTIL" <<'SH'
#!/bin/zsh
[[ $1 == status ]] || exit 1
print -r -- "$SIP_STATUS"
SH
cat > "$NVRAM" <<'SH'
#!/bin/zsh
[[ $1 == boot-args ]] || exit 1
printf 'boot-args\t%s\n' "$BOOT_ARGS"
SH
chmod +x "$CSRUTIL" "$NVRAM" || exit 1
fail=0
expect() {
    /bin/zsh "$check"
    local actual=$?
    if [[ $actual == $1 ]]; then
        print "OK  $2"
    else
        print "FAIL $2 (exit code $actual, expected $1)"
        fail=1
    fi
}
expect 0 'machine meets every requirement'
GG_OSVERSION=25G80 expect 1 'build other than 25G72'
GG_OSVERSION=25G80 GG_ARCH=arm64 expect 1 'build checked before architecture'
GG_ARCH=arm64 expect 2 'not Intel'
SIP_STATUS='System Integrity Protection status: enabled.' expect 3 'SIP enabled'
custom=$'System Integrity Protection status: unknown (Custom Configuration).\n\nConfiguration:'
SIP_STATUS="$custom"$'\n\tFilesystem Protections: enabled' expect 3 'custom SIP still protects the filesystem'
SIP_STATUS="$custom" expect 3 'filesystem protection state unknown'
SIP_STATUS="$custom"$'\n\tFilesystem Protections: disabled' expect 0 'custom SIP with filesystem protection off'
BOOT_ARGS='-v' expect 4 'AMFI flag missing'
BOOT_ARGS='not_amfi_get_out_of_my_way=1 amfi_get_out_of_my_way=0x10' expect 4 'does not accept a wrong AMFI prefix or value'
BOOT_ARGS='-igfxblt igfxonln=1 -noDC9 shikigva=80 unfairgva=7 revpatch=sbvmm ipc_control_port_options=0 -amfipassbeta brcmfx-country=#a -btlfxboardid -btlfxallowanyaddr -btlfxchipsetdetection io80211.awdl=1 igfxrpsc=1 gfxrst=4 amfi_get_out_of_my_way=0x1 amfi=0x80 vm_compressor=2' expect 0 'boot-args sample from the target machine'
exit $fail
