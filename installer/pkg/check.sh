#!/bin/zsh
set -u
export LC_ALL=C

build=${GG_OSVERSION:-$(/usr/sbin/sysctl -n kern.osversion)}
[[ $build == 25G72 ]] || exit 1
arch=${GG_ARCH:-$(/usr/bin/uname -m)}
[[ $arch == x86_64 ]] || exit 2

sip=$("${CSRUTIL:-/usr/bin/csrutil}" status) || exit 3
if [[ $sip != 'System Integrity Protection status: disabled.' ]]; then
    [[ $sip == *'(Custom Configuration).'* ]] &&
        print -r -- "$sip" | /usr/bin/grep -Eq '^[[:blank:]]*Filesystem Protections: disabled[[:blank:]]*$' || exit 3
fi

bootArgs=$("${NVRAM:-/usr/sbin/nvram}" boot-args) || exit 4
for arg in ${=bootArgs}; do
    case $arg in
        amfi_get_out_of_my_way=0x1|amfi_get_out_of_my_way=1) exit 0 ;;
    esac
done
exit 4
