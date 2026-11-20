{
  description = "tmux-share: a dedicated tmux server whose pane output is recorded to a transcript that one reader group can read";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # eachSystem: f SYSTEM PKGS, once for each supported system.
      eachSystem = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      scripts = [
        "tmux-share-attach"
        "tmux-share-preflight"
        "tmux-share-render"
        "tmux-share-tap-start"
        "tmux-share-trim"
        "tmux-share-verify"
        "tmux-share-watchdog"
      ];

      # The package. The repository's core/ tree is copied as it is laid out
      # (core/bin, core/lib, core/tmux-share-stamp): each script finds its
      # neighbours from its own location, so the layout must not change.
      #
      # bin/ holds one wrapper per command, not a symlink. TRAP: a symlink
      # changes $0 to the bin/ path, so the scripts would look for lib/ and the
      # stamp filter one level too high, and tmux-share-attach would fail to
      # load validate.sh at all. The wrapper execs the real script, so $0 is
      # right. It also puts the tools the scripts call on PATH, and loads
      # /etc/tmux-share/env when the module wrote it, so the operator's attach
      # and verify see the same paths as the units.
      mkPackage = pkgs:
        let
          inherit (pkgs) lib;

          runtimePath = lib.makeBinPath [
            pkgs.tmux
            pkgs.coreutils
            pkgs.util-linux # flock
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gawk
            pkgs.python3 # tmux-share-verify's connect probe
          ];

          mkWrapper = s: ''
            cat > "$out/bin/${s}" <<WRAPPER
            #!${pkgs.runtimeShell}
            set -eu
            if [ -r /etc/tmux-share/env ]; then
              set -a
              . /etc/tmux-share/env
              set +a
            fi
            PATH="${runtimePath}:\$PATH"
            export PATH
            exec "$out/lib/tmux-share/core/bin/${s}" "\$@"
            WRAPPER
            chmod 0755 "$out/bin/${s}"
          '';
        in
        pkgs.runCommand "tmux-share-unstable"
          {
            meta = {
              description = "tmux-share: transcript-recording tmux server with a read-only reader group";
              platforms = lib.platforms.linux;
            };
          }
          ''
            core=$out/lib/tmux-share/core
            mkdir -p "$core" "$out/bin"
            cp -R --no-preserve=mode ${./core}/. "$core"/
            chmod 0755 "$core"/bin/* "$core/tmux-share-stamp"
            chmod 0644 "$core"/lib/*
            # The scripts and the stamp filter start with "#!/usr/bin/env ...".
            # NixOS-independent: the shebangs point at the store's interpreters.
            patchShebangs "$core/bin" "$core/tmux-share-stamp"
            ${lib.concatMapStrings mkWrapper scripts}
          '';

      # checks.<system>.module-renders: evaluates the module in a minimal NixOS
      # configuration and asserts the rendered units, tmpfiles rules and tmux
      # config. Each assertion prints "ASSERT PASS|FAIL name"; the build fails
      # if any does not hold. The names are read by tests/nix/module_test.sh.
      mkModuleRendersCheck = system: pkgs:
        let
          base = [
            self.nixosModules.default
            ./examples/default.nix
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
              system.stateVersion = lib.versions.majorMinor lib.version;
            }
          ];
          good = lib.nixosSystem { inherit system; modules = base; };
          badSession = lib.nixosSystem {
            inherit system;
            modules = base ++ [ { services.tmux-share.sessionName = "bad;name"; } ];
          };
          c = good.config;

          # The text of each rendered file. Discarding the string context keeps
          # this check from building the packages the units point at: it reads
          # text, it does not run anything.
          unit = name: builtins.unsafeDiscardStringContext c.systemd.units.${name}.text;
          file = name: body: pkgs.writeText name (builtins.unsafeDiscardStringContext body);
          server = file "tmux-share-server.service" (unit "tmux-share-server.service");
          tap = file "tmux-share-tap.service" (unit "tmux-share-tap.service");
          tapTimer = file "tmux-share-tap.timer" (unit "tmux-share-tap.timer");
          trim = file "tmux-share-trim.service" (unit "tmux-share-trim.service");
          trimTimer = file "tmux-share-trim.timer" (unit "tmux-share-trim.timer");
          tmpfiles = file "tmux-share.tmpfiles" (lib.concatStringsSep "\n" c.systemd.tmpfiles.rules);
          tmuxConf = file "tmux-share.conf" (c.environment.etc."tmux-share/tmux.conf".text);
          envFile = file "tmux-share.env" (c.environment.etc."tmux-share/env".text);

          goodOk = builtins.all (a: a.assertion) good.config.assertions;
          rejectsSession = builtins.any
            (a: !a.assertion && lib.hasInfix "sessionName" a.message)
            badSession.config.assertions;
        in
        pkgs.runCommand "tmux-share-module-renders" { } ''
          fails=0

          # assert_that NAME COMMAND...: PASS when COMMAND succeeds.
          assert_that() {
            local name=$1
            shift
            if "$@" >/dev/null 2>&1; then
              echo "ASSERT PASS $name"
            else
              echo "ASSERT FAIL $name"
              fails=$((fails + 1))
            fi
          }

          # refute_that NAME COMMAND...: PASS when COMMAND fails.
          refute_that() {
            local name=$1
            shift
            if "$@" >/dev/null 2>&1; then
              echo "ASSERT FAIL $name"
              fails=$((fails + 1))
            else
              echo "ASSERT PASS $name"
            fi
          }

          # ---- evaluation-time facts (true / false) ----
          assert_that good-config-assertions-hold ${lib.boolToString goodOk}
          assert_that session-name-semicolon-rejected ${lib.boolToString rejectsSession}

          # ---- the server unit ----
          # TRAP: ExecStartPost carries the leading "-".
          assert_that server-exec-start-post-dash grep -qx 'ExecStartPost=-/nix/store/.*' ${server}
          assert_that server-exec-start-post-tap-start grep -qx 'ExecStartPost=-/nix/store/.*/bin/tmux-share-tap-start' ${server}
          assert_that server-exec-start-foreground grep -qx 'ExecStart=/nix/store/.*/bin/tmux -D -S /run/tmux-share/tmux.sock -f /etc/tmux-share/tmux.conf' ${server}
          assert_that server-restart-on-failure grep -qx 'Restart=on-failure' ${server}

          # TRAP: no UMask anywhere in the module's units.
          refute_that no-umask-in-units grep -qi 'UMask' ${server} ${tap} ${tapTimer} ${trim} ${trimTimer}

          # ---- timers and oneshots ----
          # TRAP: AccuracySec=1s on both timers.
          assert_that tap-timer-accuracy-1s grep -qx 'AccuracySec=1s' ${tapTimer}
          assert_that trim-timer-accuracy-1s grep -qx 'AccuracySec=1s' ${trimTimer}
          assert_that tap-timer-20s grep -qx 'OnUnitActiveSec=20s' ${tapTimer}
          assert_that trim-timer-5min grep -qx 'OnUnitActiveSec=5min' ${trimTimer}
          assert_that tap-oneshot grep -qx 'Type=oneshot' ${tap}
          assert_that trim-oneshot grep -qx 'Type=oneshot' ${trim}
          # TRAP: a oneshot must not stay active, or its timer never fires it again.
          refute_that no-remain-after-exit-yes grep -q 'RemainAfterExit=yes' ${tap} ${trim}

          # ---- tmpfiles: the modes of systemd/tmux-share.tmpfiles ----
          assert_that tmpfiles-dir-0710 grep -qx 'd /run/tmux-share 0710 root tmux-share - -' ${tmpfiles}
          assert_that tmpfiles-transcript-0640 grep -qx 'f /run/tmux-share/transcript.log 0640 root tmux-share - -' ${tmpfiles}
          assert_that tmpfiles-lock-0600 grep -qx 'f /run/tmux-share.lock 0600 root root - -' ${tmpfiles}
          # TRAP: no rule creates the socket.
          refute_that tmpfiles-no-socket-rule grep -q 'tmux\.sock' ${tmpfiles}

          # ---- the tmux configuration ----
          assert_that tmux-conf-exit-empty grep -qx 'set -g exit-empty on' ${tmuxConf}
          assert_that tmux-conf-new-session grep -qx 'new-session -d -s tmux-hermes -c /root' ${tmuxConf}
          assert_that tmux-conf-default-shell grep -q '^set -g default-shell /nix/store/' ${tmuxConf}
          # Nothing global beyond the two settings and the session.
          refute_that tmux-conf-no-other-settings grep -Ev '^(# |$|set -g (exit-empty|default-shell) |new-session -d -s [A-Za-z0-9_-]+ -c /root$)' ${tmuxConf}

          # ---- the env file the units read ----
          assert_that env-session grep -qx "TMUX_SHARE_SESSION='tmux-hermes'" ${envFile}
          assert_that env-max-bytes grep -qx "TMUX_SHARE_MAX_BYTES='2097152'" ${envFile}

          if [ "$fails" -ne 0 ]; then
            echo "module-renders: $fails assertion(s) failed" >&2
            exit 1
          fi
          touch "$out"
        '';
    in
    {
      packages = eachSystem (_: pkgs: { default = mkPackage pkgs; });

      # The module takes this flake so that `package` defaults to our build.
      nixosModules.default = import ./nix/module.nix { inherit self; };
      nixosModules.tmux-share = self.nixosModules.default;

      checks = eachSystem (system: pkgs: {
        module-renders = mkModuleRendersCheck system pkgs;
      });
    };
}
