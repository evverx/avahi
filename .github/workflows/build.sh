#!/bin/bash

set -eux
set -o pipefail

case "$1" in
    install-build-deps)
        sed -i -e '/^#\s*deb-src.*\smain\s\+restricted/s/^#//' /etc/apt/sources.list
        apt-get update -y
        apt-get build-dep -y avahi
        apt-get install -y libevent-dev qtbase5-dev
        apt-get install -y gcc clang
        apt-get install -y avahi-daemon

        # install dfuzzer to catch issues like https://github.com/lathiat/avahi/issues/375
        apt-get install -y libglib2.0-dev meson
        git clone --depth=1 https://github.com/dbus-fuzzer/dfuzzer
        pushd dfuzzer
        meson --buildtype=release build
        ninja -C ./build -v
        ninja -C ./build install
        popd
        ;;
    build)
        ./bootstrap.sh --enable-tests --prefix=/usr
        make -j"$(nproc)" V=1
        make check VERBOSE=1
        make install

        systemctl daemon-reload
        if ! systemctl restart avahi-daemon; then
            journalctl -u avahi-daemon -e
            exit 1
	fi
        if ! dfuzzer -v -n org.freedesktop.Avahi; then
            journalctl -u avahi-daemon -b
            exit 1
	fi
        ;;
    *)
        printf '%s' "Unknown command '$1'" >&2
        exit 1
esac
