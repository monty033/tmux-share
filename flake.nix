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
        "tmux-share"
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
      # stamp filter one level too high, and tmux-share would fail to
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
            # Bind the install root at build time and escape it for the
            # heredoc, so the wrapper never depends on an unset variable: an
            # unescaped runtime variable here expands to nothing during the
            # build and every command in this package fails with ENOENT.
            root=${placeholder "out"}
            export TMUX_SHARE_LIBDIR="\$root/lib/tmux-share/core/lib"
            exec "\$root/lib/tmux-share/core/bin/${s}" "\$@"
            WRAPPER
            chmod 0755 "$out/bin/${s}"
          '';
        in
        pkgs.runCommand "tmux-share-unstable"
          {
            meta = {
              description = "tmux-share: transcript-recording tmux server with a read-only reader group";
              platforms = lib.platforms.linux;
              license = lib.licenses.mit;
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

          # The account variants. The module is applied as it is; only the
          # `user` option and the account declarations differ.
          withUser = extra: lib.nixosSystem { inherit system; modules = base ++ [ extra ]; };
          alice = withUser {
            services.tmux-share.user = "alice";
            users.users.alice = { isNormalUser = true; home = "/srv/alice"; };
          };
          # Not declared in users.users: units for it would fail at boot.
          carol = withUser { services.tmux-share.user = "carol"; };
          # An account whose primary group is not named like it, as every normal
          # NixOS account is ("users"), and one that has a group of its own.
          erin = withUser {
            services.tmux-share.user = "erin";
            users.users.erin = { isNormalUser = true; group = "erin"; };
            users.groups.erin = { };
          };
          # Declared with no home beyond "/", and declared with no primary group.
          frank = withUser {
            services.tmux-share.user = "frank";
            users.users.frank = { isSystemUser = true; group = "users"; home = "/"; };
          };
          dave = withUser {
            services.tmux-share.user = "dave";
            users.users.dave.isSystemUser = true;
          };
          explicitRoot = withUser { services.tmux-share.user = "root"; };
          badUser = withUser { services.tmux-share.user = "bad;name"; };
          # examples/default.nix names hermes-reader as the readerUser.
          sameAsReader = withUser { services.tmux-share.user = "hermes-reader"; };
          # The five options a deployment may set beyond the ones the module
          # already had. One system sets all of them at once, and one system
          # per option sets a value the module must refuse.
          custom = withUser {
            services.tmux-share = {
              unitPrefix = "tmux-admin";
              terminal = "tmux-256color";
              historyLimit = 2000;
              sessionPath = [ "/usr/local/bin" "/usr/bin" "/bin" ];
              serverAccessReadOnly = "guest";
            };
          };
          # A prefix systemd itself would accept, and the module refuses: the
          # module's own assertion is what has to catch it.
          badPrefix = withUser { services.tmux-share.unitPrefix = "tmux:admin"; };
          badTerminal = withUser { services.tmux-share.terminal = "xterm;evil"; };
          badHistory = withUser { services.tmux-share.historyLimit = 0; };
          badPath = withUser { services.tmux-share.sessionPath = [ "/usr/bin;evil" ]; };
          badAccess = withUser { services.tmux-share.serverAccessReadOnly = "guest;evil"; };
          # The read-only account is the one that owns the server.
          accessIsOwner = withUser { services.tmux-share.serverAccessReadOnly = "root"; };
          # The module as it was before the `user` option, frozen in
          # tests/nix/base-module.nix. A default configuration has to render the
          # same text with this one, so a host that never sets `user` is unchanged.
          baseSystem = lib.nixosSystem {
            inherit system;
            modules = [ (import ./tests/nix/base-module.nix { inherit self; }) ] ++ builtins.tail base;
          };

          # The text of each rendered file. Discarding the string context keeps
          # this check from building the packages the units point at: it reads
          # text, it does not run anything.
          unitOf = cfg: name: builtins.unsafeDiscardStringContext cfg.systemd.units.${name}.text;
          # The text of a unit that may not exist: a unit the module did not
          # create reads as empty, so a missing one is a FAIL and not a failed
          # evaluation.
          unitText = cfg: name:
            if builtins.hasAttr name cfg.systemd.units then unitOf cfg name else "";
          hasUnit = cfg: name: builtins.hasAttr name cfg.systemd.units;
          tmpfilesOf = cfg: builtins.unsafeDiscardStringContext (lib.concatStringsSep "\n" cfg.systemd.tmpfiles.rules);
          etcOf = cfg: name: builtins.unsafeDiscardStringContext cfg.environment.etc.${name}.text;
          unit = unitOf c;
          file = name: body: pkgs.writeText name (builtins.unsafeDiscardStringContext body);
          server = file "tmux-share-server.service" (unit "tmux-share-server.service");
          tap = file "tmux-share-tap.service" (unit "tmux-share-tap.service");
          tapTimer = file "tmux-share-tap.timer" (unit "tmux-share-tap.timer");
          trim = file "tmux-share-trim.service" (unit "tmux-share-trim.service");
          trimTimer = file "tmux-share-trim.timer" (unit "tmux-share-trim.timer");
          tmpfiles = file "tmux-share.tmpfiles" (tmpfilesOf c);
          tmuxConf = file "tmux-share.conf" (c.environment.etc."tmux-share/tmux.conf".text);
          envFile = file "tmux-share.env" (c.environment.etc."tmux-share/env".text);

          goodOk = builtins.all (a: a.assertion) good.config.assertions;
          rejectsSession = builtins.any
            (a: !a.assertion && lib.hasInfix "sessionName" a.message)
            badSession.config.assertions;
          rejects = what: sys: builtins.any
            (a: !a.assertion && lib.hasInfix what a.message)
            sys.config.assertions;
          holds = sys: builtins.all (a: a.assertion) sys.config.assertions;

          # Store hashes differ between the two package builds, and nothing else
          # may: each "/nix/store/<hash>-" is replaced by a fixed one.
          norm = text: lib.concatStrings (map
            (part: if builtins.isList part then "/nix/store/HASH-" else part)
            (builtins.split "/nix/store/[a-z0-9]{32}-" text));
          sameText = a: b: norm a == norm b;
          sameAsBase = other: name: sameText (unitOf other.config name) (unitOf baseSystem.config name);
          unitNames = [
            "tmux-share-server.service"
            "tmux-share-tap.service"
            "tmux-share-tap.timer"
            "tmux-share-trim.service"
            "tmux-share-trim.timer"
          ];
          # Every rendered file the option could reach, as one comparison.
          renderedSameAsBase = other:
            builtins.all (sameAsBase other) unitNames
            && sameText (tmpfilesOf other.config) (tmpfilesOf baseSystem.config)
            && sameText (etcOf other.config "tmux-share/tmux.conf") (etcOf baseSystem.config "tmux-share/tmux.conf")
            && sameText (etcOf other.config "tmux-share/env") (etcOf baseSystem.config "tmux-share/env")
            # Owner, group and mode of the two files are part of what "unchanged" means.
            && etcSameAsBase other "tmux-share/tmux.conf"
            && etcSameAsBase other "tmux-share/env";

          aliceFile = name: body: file "alice-${name}" body;
          aliceServer = aliceFile "server" (unitOf alice.config "tmux-share-server.service");
          aliceTap = aliceFile "tap" (unitOf alice.config "tmux-share-tap.service");
          aliceTrim = aliceFile "trim" (unitOf alice.config "tmux-share-trim.service");
          aliceTapTimer = aliceFile "tap-timer" (unitOf alice.config "tmux-share-tap.timer");
          aliceTrimTimer = aliceFile "trim-timer" (unitOf alice.config "tmux-share-trim.timer");
          aliceTmpfiles = aliceFile "tmpfiles" (tmpfilesOf alice.config);
          aliceConf = aliceFile "conf" (etcOf alice.config "tmux-share/tmux.conf");
          aliceEnv = aliceFile "env" (etcOf alice.config "tmux-share/env");
          frankConf = file "frank-conf" (etcOf frank.config "tmux-share/tmux.conf");
          erinTmpfiles = file "erin-tmpfiles" (tmpfilesOf erin.config);
          # How the two rendered files are owned: only the account differs.
          etcAttrs = cfg: name: {
            inherit (cfg.environment.etc.${name}) mode user group;
          };
          etcSameAsBase = other: name: etcAttrs other.config name == etcAttrs baseSystem.config name;
          aliceEtc = name: etcAttrs alice.config name;
          # The files the custom configuration renders: the five units under
          # their new names, and the tmux configuration with the five settings.
          customFile = name: body: file "custom-${name}" body;
          customServer = customFile "server" (unitText custom.config "tmux-admin-server.service");
          customTap = customFile "tap" (unitText custom.config "tmux-admin-tap.service");
          customTapTimer = customFile "tap-timer" (unitText custom.config "tmux-admin-tap.timer");
          customTrim = customFile "trim" (unitText custom.config "tmux-admin-trim.service");
          customTrimTimer = customFile "trim-timer" (unitText custom.config "tmux-admin-trim.timer");
          customConf = customFile "conf" (etcOf custom.config "tmux-share/tmux.conf");
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

          # ---- the user option: root stays the default ----
          # The rendered text with no `user` set, and with "root" set on purpose,
          # equals the text of the module before the option existed.
          assert_that user-default-render-identical-to-base ${lib.boolToString (renderedSameAsBase good)}
          assert_that user-root-render-identical-to-base ${lib.boolToString (renderedSameAsBase explicitRoot)}
          # TRAP: a User=root line would be harmless to systemd and still change
          # the text, so the default must declare no User= at all.
          refute_that user-default-declares-no-user grep -q 'User=' ${server} ${tap} ${trim}

          # ---- the user option: a non-root account ----
          assert_that user-alice-assertions-hold ${lib.boolToString (holds alice)}
          assert_that user-alice-env grep -qx "TMUX_SHARE_USER='alice'" ${aliceEnv}
          assert_that user-alice-tmpfiles-dir grep -qx 'd /run/tmux-share 0710 alice tmux-share - -' ${aliceTmpfiles}
          assert_that user-alice-tmpfiles-transcript grep -qx 'f /run/tmux-share/transcript.log 0640 alice tmux-share - -' ${aliceTmpfiles}
          # The lock's group is the primary group NixOS gives the account ("users"
          # for a normal user), not a group named after it: that one does not
          # exist, and systemd-tmpfiles fails the rule at boot when it does not.
          assert_that user-alice-primary-group-is-users ${lib.boolToString (alice.config.users.users.alice.group == "users")}
          assert_that user-alice-tmpfiles-lock grep -qx 'f /run/tmux-share.lock 0600 alice users - -' ${aliceTmpfiles}
          refute_that user-alice-lock-group-not-named-after-the-account grep -q 'alice alice' ${aliceTmpfiles}
          assert_that user-own-group-tmpfiles-lock grep -qx 'f /run/tmux-share.lock 0600 erin erin - -' ${erinTmpfiles}
          # The two rendered files belong to the account the server runs as, with
          # group read for the reader group, as install.sh makes them.
          assert_that user-alice-etc-conf-owned ${lib.boolToString (aliceEtc "tmux-share/tmux.conf" == { mode = "0640"; user = "alice"; group = "tmux-share"; })}
          assert_that user-alice-etc-env-owned ${lib.boolToString (aliceEtc "tmux-share/env" == { mode = "0640"; user = "alice"; group = "tmux-share"; })}
          # The reader group never owns anything and never gains write: no
          # tmux-share rule may name root once the owner is alice.
          refute_that user-alice-tmpfiles-no-root grep -E '^[df] /run/tmux-share.* root ' ${aliceTmpfiles}
          assert_that user-alice-server-runs-as grep -qx 'User=alice' ${aliceServer}
          assert_that user-alice-tap-runs-as grep -qx 'User=alice' ${aliceTap}
          assert_that user-alice-trim-runs-as grep -qx 'User=alice' ${aliceTrim}
          # Timers do not run anything themselves; a User= there is not valid.
          refute_that user-alice-timers-no-user grep -q 'User=' ${aliceTapTimer} ${aliceTrimTimer}
          # The two traps stay: a non-root owner must not bring UMask or
          # RuntimeDirectory back in.
          refute_that user-alice-no-umask-no-runtimedirectory grep -qiE 'UMask|RuntimeDirectory' ${aliceServer} ${aliceTap} ${aliceTrim}
          assert_that user-alice-session-in-the-account-home grep -qx 'new-session -d -s tmux-hermes -c /srv/alice' ${aliceConf}
          refute_that user-alice-session-not-in-root grep -q '/root' ${aliceConf}
          assert_that user-home-slash-session-in-slash grep -qx 'new-session -d -s tmux-hermes -c /' ${frankConf}
          # The comment says what the -c is: no home for "/", the home otherwise.
          assert_that user-comment-names-the-slash grep -q '^# .*-c /: frank has no home other than /' ${frankConf}
          assert_that user-comment-names-the-home grep -q '^# .*-c /srv/alice: the shell starts in the home of alice' ${aliceConf}

          # ---- the user option: refused values ----
          assert_that user-semicolon-rejected ${lib.boolToString (rejects "services.tmux-share.user must be a plain account name" badUser)}
          assert_that user-undeclared-rejected ${lib.boolToString (rejects "must be root or an account declared in users.users" carol)}
          assert_that user-undeclared-explains-boot-failure ${lib.boolToString (rejects "fail at boot" carol)}
          assert_that user-without-primary-group-rejected ${lib.boolToString (rejects "primary group of services.tmux-share.user cannot be determined" dave)}
          assert_that user-alice-not-rejected-as-undeclared ${lib.boolToString (!(rejects "must be root or an account declared" alice))}
          assert_that user-equal-to-reader-rejected ${lib.boolToString (rejects "must not be the readerUser" sameAsReader)}

          # ---- the five options a deployment may set beyond the old ones ----
          # A configuration that sets all of them holds together.
          assert_that custom-config-assertions-hold ${lib.boolToString (holds custom)}

          # ---- the unit prefix ----
          assert_that unit-prefix-names-the-server ${lib.boolToString (hasUnit custom.config "tmux-admin-server.service")}
          assert_that unit-prefix-names-the-tap ${lib.boolToString (hasUnit custom.config "tmux-admin-tap.service")}
          assert_that unit-prefix-names-the-tap-timer ${lib.boolToString (hasUnit custom.config "tmux-admin-tap.timer")}
          assert_that unit-prefix-names-the-trim ${lib.boolToString (hasUnit custom.config "tmux-admin-trim.service")}
          assert_that unit-prefix-names-the-trim-timer ${lib.boolToString (hasUnit custom.config "tmux-admin-trim.timer")}
          # The old names are gone: a host that renames its units must not keep
          # the old ones, or it runs two servers on one host.
          refute_that unit-prefix-drops-the-old-names grep -q 'tmux-share-server\.service' ${customServer} ${customTap} ${customTrim}
          # The watchdog and the trimmer wait for the server under its new name.
          assert_that unit-prefix-orders-the-tap-after-the-server grep -qx 'After=tmux-admin-server.service' ${customTap}
          assert_that unit-prefix-orders-the-trim-after-the-server grep -qx 'After=tmux-admin-server.service' ${customTrim}
          # The default prefix keeps the names the templates in systemd/ use.
          assert_that unit-prefix-default-keeps-the-names ${lib.boolToString (hasUnit c "tmux-share-server.service" && hasUnit c "tmux-share-trim.timer")}
          assert_that unit-prefix-invalid-rejected ${lib.boolToString (rejects "services.tmux-share.unitPrefix must be a plain name" badPrefix)}

          # ---- the terminal type ----
          assert_that terminal-writes-default-terminal grep -qx 'set -g default-terminal tmux-256color' ${customConf}
          # The default writes nothing: the module has never written one, and a
          # deployment that sets nothing must render what it rendered before.
          refute_that terminal-default-writes-nothing grep -q 'default-terminal' ${tmuxConf}
          assert_that terminal-invalid-rejected ${lib.boolToString (rejects "services.tmux-share.terminal must be null or a plain terminal name" badTerminal)}

          # ---- the history limit ----
          assert_that history-limit-writes-history-limit grep -qx 'set -g history-limit 2000' ${customConf}
          refute_that history-limit-default-writes-nothing grep -q 'history-limit' ${tmuxConf}
          assert_that history-limit-not-positive-rejected ${lib.boolToString (rejects "services.tmux-share.historyLimit must be null or a positive integer" badHistory)}

          # ---- the session's PATH ----
          assert_that session-path-writes-set-environment grep -qx 'set-environment -g PATH "/usr/local/bin:/usr/bin:/bin"' ${customConf}
          refute_that session-path-default-writes-nothing grep -q 'set-environment' ${tmuxConf}
          assert_that session-path-invalid-rejected ${lib.boolToString (rejects "services.tmux-share.sessionPath must be null or a non-empty list" badPath)}

          # ---- the read-only server access ----
          assert_that server-access-writes-the-account grep -qx 'server-access -a -r guest' ${customConf}
          refute_that server-access-default-writes-nothing grep -q 'server-access' ${tmuxConf}
          assert_that server-access-invalid-rejected ${lib.boolToString (rejects "services.tmux-share.serverAccessReadOnly must be null or a plain account name" badAccess)}
          assert_that server-access-not-the-owner-rejected ${lib.boolToString (rejects "must not be the account that owns the server" accessIsOwner)}

          # The custom configuration writes the five settings and nothing else.
          refute_that custom-conf-no-other-settings grep -Ev '^(# |$|set -g (exit-empty|default-shell|default-terminal|history-limit) |server-access -a -r [A-Za-z0-9_.-]+$|set-environment -g PATH "[^"]+"$|new-session -d -s [A-Za-z0-9_-]+ -c /root$)' ${customConf}

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
