{ pkgs }: {
  deps = [
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.curl
    pkgs.gnutar
    pkgs.gzip
    pkgs.procps
    pkgs.openssl
    pkgs.proot
    pkgs.caddy
    pkgs.ttyd
    pkgs.xorg.xorgserver
    pkgs.xorg.xdpyinfo
    pkgs.x11vnc
    pkgs.fluxbox
    pkgs.xterm
    pkgs.python3Packages.websockify
  ];
}
