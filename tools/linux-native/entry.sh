#!/usr/bin/env bash
# Nur das Broker-Kind betritt die private ABI-Umgebung; Hostprogramme behalten dessen Snapshot.
set -euo pipefail
fail() { printf 'Fastra optional runtime: %s\n' "$*" >&2; exit 2; }
launcher=$(readlink -f -- "${BASH_SOURCE[0]}")
root=$(CDPATH= cd -- "$(dirname -- "$launcher")/.." && pwd -P)
runtime=$root/runtime
lib=$runtime/usr/lib/x86_64-linux-gnu
[[ $# -ge 1 ]] || fail 'Missing GUI executable.'
[[ $(readlink -f -- "$1") == "$root/app/libexec/fastra-linux" ]] || fail 'Entry accepts only its packaged GUI.'
[[ ${FASTRA_INTERNAL_HOST_FD:-} == 3 && -S /proc/self/fd/3 ]] || fail 'The GTK-free outer host broker is required.'
[[ $runtime != *:* && ! $runtime =~ [[:cntrl:]] ]] || fail 'Runtime path contains an unsupported separator or control character.'
[[ -x $lib/ld-linux-x86-64.so.2 && -x $runtime/usr/bin/bwrap ]] || fail 'Private loader or Bubblewrap is missing.'
[[ -d $lib/webkitgtk-6.0 && -d /usr/lib/x86_64-linux-gnu/webkitgtk-6.0 ]] || fail 'Host WebKit helper mount target is missing; this host layout is not verified.'
[[ -f /usr/bin/bwrap && -f /usr/bin/xdg-dbus-proxy ]] || fail 'Host sandbox helper mount targets are missing.'
loader=$(readlink -f -- /lib64/ld-linux-x86-64.so.2)
case $loader in
 /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2|/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2|/usr/lib/ld-linux-x86-64.so.2|/usr/lib64/ld-linux-x86-64.so.2|/lib64/ld-linux-x86-64.so.2|/lib/ld-linux-x86-64.so.2) ;;
 *) fail 'Host ELF loader layout is not verified.' ;;
esac
[[ -f $loader ]] || fail 'Host ELF loader target is missing.'
cache_home=${XDG_CACHE_HOME:-${HOME:?}/.cache}
[[ $cache_home == /* ]] || fail 'Cache directory must be absolute.'
key=$(printf '%s' "$runtime" | sha256sum);key=${key%% *}
cache_parent=$cache_home/fastra-native
[[ ! -L $cache_parent ]] || fail 'Cache parent must not be a symlink.'
mkdir -p -m 700 -- "$cache_parent"
[[ $(stat -c %u -- "$cache_parent") == "$(id -u)" ]] || fail 'Cache parent ownership is unsafe.'
chmod 700 -- "$cache_parent"
cache=$cache_parent/$key
[[ ! -L $cache ]] || fail 'Cache directory must not be a symlink.'
mkdir -p -m 700 -- "$cache"
[[ $(stat -c %u -- "$cache") == "$(id -u)" && $(stat -c %a -- "$cache") == 700 ]] || fail 'Cache ownership or permissions are unsafe.'
# C-String-Escapes im Pixbufcache und Sed-Ersatzzeichen getrennt maskieren.
c_prefix=$(printf '%s' "$runtime" | sed 's/\\/\\\\/g; s/"/\\"/g')
sed_prefix=$(printf '%s' "$c_prefix" | sed 's/[\\&|]/\\&/g')
temporary=$(mktemp "$cache/.pixbuf.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
sed "s|\"/usr/|\"$sed_prefix/usr/|g" "$lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" > "$temporary"
mv -fT -- "$temporary" "$cache/pixbuf.cache"
trap - EXIT
shadow=$cache/shadow-paths.json
canonical_webkit=$(readlink -f /usr/lib/x86_64-linux-gnu/webkitgtk-6.0)
canonical_bwrap=$(readlink -f /usr/bin/bwrap)
canonical_proxy=$(readlink -f /usr/bin/xdg-dbus-proxy)
for target in "$canonical_webkit" "$canonical_bwrap" "$canonical_proxy"; do
 [[ $target =~ ^/[A-Za-z0-9_./+-]+$ ]] || fail 'Canonical helper path is not a verified system layout.'
done
shadow_temporary=$(mktemp "$cache/.shadow.XXXXXX")
trap 'rm -f -- "$shadow_temporary"' EXIT
# Statische bekannte Ziele und der tatsächlich aufgelöste Loader stehen gemeinsam bereit.
printf '{"format":1,"scope":"known-runtime-shadow-paths","shadowed_paths":[{"path":"/lib64/ld-linux-x86-64.so.2","canonical_target":"%s","kind":"file"},{"path":"/usr/lib/x86_64-linux-gnu/webkitgtk-6.0","canonical_target":"%s","kind":"directory"},{"path":"/usr/bin/bwrap","canonical_target":"%s","kind":"file"},{"path":"/usr/bin/xdg-dbus-proxy","canonical_target":"%s","kind":"file"}]}\n' \
 "$loader" "$canonical_webkit" "$canonical_bwrap" "$canonical_proxy" > "$shadow_temporary"
mv -fT -- "$shadow_temporary" "$shadow"
trap - EXIT
# Die Bind-Ziele müssen bereits existieren. Es werden keine Hostverzeichnisse erzeugt.
# Keine --preserve-fds-Option: der verifizierte Brokervertrag erhält FD3 und Marker.
exec env -u LD_PRELOAD -u LD_LIBRARY_PATH -u LD_AUDIT "$lib/ld-linux-x86-64.so.2" --library-path "$lib:$runtime/usr/lib:$runtime/usr/lib64" "$runtime/usr/bin/bwrap" \
 --unshare-user --unshare-pid --bind / / --proc /proc --dev-bind /dev /dev --ro-bind /sys /sys \
 --ro-bind "$lib/ld-linux-x86-64.so.2" "$loader" \
 --ro-bind "$lib/webkitgtk-6.0" /usr/lib/x86_64-linux-gnu/webkitgtk-6.0 \
 --ro-bind "$runtime/usr/bin/bwrap" /usr/bin/bwrap \
 --ro-bind "$runtime/usr/bin/xdg-dbus-proxy" /usr/bin/xdg-dbus-proxy \
 --unsetenv LD_PRELOAD --unsetenv LD_AUDIT --unsetenv GIO_EXTRA_MODULES --unsetenv WEBKIT_EXEC_PATH \
 --unsetenv WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS --unsetenv GI_TYPELIB_PATH \
 --unsetenv GST_PLUGIN_PATH --unsetenv GST_PLUGIN_SYSTEM_PATH --unsetenv GST_PLUGIN_SCANNER \
 --unsetenv GST_PLUGIN_PATH_1_0 --unsetenv GST_PLUGIN_SYSTEM_PATH_1_0 --unsetenv GST_PLUGIN_SCANNER_1_0 --unsetenv GST_REGISTRY_1_0 \
 --unsetenv GTK_MODULES \
 --setenv LD_LIBRARY_PATH "$root/app/lib:$lib:$runtime/usr/lib:$runtime/usr/lib64" \
 --setenv XDG_DATA_DIRS "$runtime/usr/share:/usr/local/share:/usr/share" \
 --setenv GSETTINGS_SCHEMA_DIR "$runtime/usr/share/glib-2.0/schemas" \
 --setenv GIO_MODULE_DIR "$lib/gio/modules" \
 --setenv GDK_PIXBUF_MODULE_FILE "$cache/pixbuf.cache" \
 --setenv GDK_PIXBUF_MODULEDIR "$lib/gdk-pixbuf-2.0/2.10.0/loaders" \
 --setenv GTK_PATH "$lib/gtk-4.0" \
 --setenv GTK_EXE_PREFIX "$runtime/usr" \
 --setenv GST_PLUGIN_SYSTEM_PATH "$lib/gstreamer-1.0" \
 --setenv GST_PLUGIN_SCANNER "$lib/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner" \
 --setenv GST_REGISTRY "$cache/gstreamer.registry" \
 --setenv FASTRA_NATIVE_RUNTIME 1 \
 --setenv FASTRA_NATIVE_SHADOW_MANIFEST "$shadow" \
 "$@"
