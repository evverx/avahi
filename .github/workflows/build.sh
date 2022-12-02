#!/bin/bash

set -eux
set -o pipefail

export ASAN_UBSAN=${ASAN_UBSAN:-false}

case "$1" in
    install-build-deps)
        sed -i -e '/^#\s*deb-src.*\smain\s\+restricted/s/^#//' /etc/apt/sources.list
        apt-get update -y
        apt-get build-dep -y avahi
        apt-get install -y libevent-dev qtbase5-dev gcc clang avahi-daemon ncat

        # install dfuzzer to catch issues like https://github.com/lathiat/avahi/issues/375
        apt-get install -y libglib2.0-dev meson
        git clone --depth=1 https://github.com/dbus-fuzzer/dfuzzer
        pushd dfuzzer
        meson --buildtype=release build
        ninja -C ./build -v
        ninja -C ./build install
        popd

        # install radamsa to catch issues like https://github.com/lathiat/avahi/pull/330
        # and https://github.com/lathiat/avahi/issues/338
        git clone --depth=1 https://gitlab.com/akihe/radamsa
        pushd radamsa
        make -j"$(nproc)" V=1
        make install
        popd
        ;;
    build)
        if [[ "$ASAN_UBSAN" == true ]]; then
            export CFLAGS="-fsanitize=address,undefined -g -fno-omit-frame-pointer"
            export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1
            export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1
        fi

        ./bootstrap.sh --enable-tests --prefix=/usr
        make -j"$(nproc)" V=1
        make check VERBOSE=1

        if [[ "$ASAN_UBSAN" == true ]]; then
            sed -i "/\[Service\]/aEnvironment=ASAN_OPTIONS=$ASAN_OPTIONS UBSAN_OPTIONS=$UBSAN_OPTIONS" avahi-daemon/avahi-daemon.service
            sed -i '/^ExecStart=/s/$/ --no-chroot --no-drop-root/' avahi-daemon/avahi-daemon.service
        fi

        make install

        systemctl daemon-reload
        systemctl cat avahi-daemon
        if ! systemctl restart avahi-daemon; then
            journalctl -u avahi-daemon -e
            exit 1
        fi

        cat <<'EOL' >commands
HELP
RESOLVE-HOSTNAME a
RESOLVE-HOSTNAME-IPV6 a.
RESOLVE-HOSTNAME-IPV4 a..b
RESOLVE-ADDRESS 127.0.0.1
BROWSE-DNS-SERVERS
BROWSE-DNS-SERVERS-IPV4
BROWSE-DNS-SERVERS-IPV6
EOL

        timeout 60 bash -c 'while :; do radamsa commands | ncat -U /run/avahi-daemon/socket; done' || true

        if ! dfuzzer -v -n org.freedesktop.Avahi; then
            journalctl -u avahi-daemon -b
            exit 1
        fi

        # TODO: look for coredumps and ASan/UBsan backtraces
        systemctl stop avahi-daemon
        journalctl -u avahi-daemon -b
        ;;
    *)
        printf '%s' "Unknown command '$1'" >&2
        exit 1
esac
