# nix/module.nix: the NixOS form of systemd/ (the plain-systemd install path).
#
# What mirrors what:
#   systemd/tmux-share-server.service   systemd.services.tmux-share-server
#   systemd/tmux-share-tap.service      systemd.services.tmux-share-tap
#   systemd/tmux-share-tap.timer        systemd.timers.tmux-share-tap
#   systemd/tmux-share-trim.service     systemd.services.tmux-share-trim
#   systemd/tmux-share-trim.timer       systemd.timers.tmux-share-trim
#   systemd/tmux-share.tmpfiles         systemd.tmpfiles.rules
#   systemd/tmux-share.sysusers         users.groups (the reader group only)
#   the server's EnvironmentFile        /etc/tmux-share/env (environment.etc),
#                                       the same shape tmux-share-render prints
#   the server's -f file                /etc/tmux-share/tmux.conf (environment.etc)
#
# Import through the flake (nixosModules.default). The module takes the flake
# as an argument so that the `package` option defaults to this flake's build:
#   import ./nix/module.nix { inherit self; }
#
# Comments that start with "TRAP:" name the measured problem a line answers.
{ self }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optionalAttrs types;

  cfg = config.services.tmux-share;

  # The alphabets of core/lib/validate.sh. The scripts refuse a value outside
  # them at run time; the module refuses it at evaluation time instead.
  sessionRe = "[A-Za-z0-9][A-Za-z0-9_-]{0,63}";
  nameRe = "[A-Za-z0-9_][A-Za-z0-9_.-]*";
  pathRe = "/[A-Za-z0-9_./-]*[A-Za-z0-9_-]";
  matches = re: value: builtins.match re value != null;

  bin = name: "${cfg.package}/bin/${name}";
  # The env file names these so that the scripts find their neighbours even
  # when run through a bin/ wrapper (see the flake's package).
  libDir = "${cfg.package}/lib/tmux-share/core/lib";
  stamp = "${cfg.package}/lib/tmux-share/core/tmux-share-stamp";

  sock = "${cfg.directory}/${cfg.socketName}";
  transcript = "${cfg.directory}/${cfg.transcriptName}";
  # A sibling of the directory, never a child: the reader can traverse the
  # directory, and the lock has to stay out of its reach.
  lock = "${cfg.directory}.lock";
  notReadyMarker = "${cfg.directory}/.notready-since";
  rebuildMarker = "${cfg.directory}/.rebuild-required";

  tmuxConf = "/etc/tmux-share/tmux.conf";
  envFile = "/etc/tmux-share/env";

  # The primary group of `user`, read from the account's declaration. The lock
  # is owned by that group because that is the group tmux and the scripts give
  # every file the account creates, so the lock agrees with the socket and with
  # what tmux-share-verify checks. A group named after the account would not
  # exist on a normal NixOS account, whose primary group is "users". Empty when
  # the declaration names none, which an assertion below turns into an error.
  userGroup =
    if cfg.user == "root" then "root"
    else lib.attrByPath [ cfg.user "group" ] "" config.users.users;
  declaredHome = lib.attrByPath [ cfg.user "home" ] "" config.users.users;

  # Where the session's shell starts. root keeps its literal /root, so a host
  # that never sets `user` renders the same file as before. Any other account
  # starts in the home NixOS declares for it, and in / when the declaration has
  # none: /root would be a directory that account cannot enter.
  startDir =
    if cfg.user == "root" then "/root"
    else if declaredHome == "" then "/"
    else declaredHome;
  # systemd runs a unit as root when User= is absent, so root declares nothing
  # and the units of a host that never sets `user` render exactly as before.
  runAs = optionalAttrs (cfg.user != "root") { User = cfg.user; };
  # Says what the rendered -c really is, so the comment and the value cannot
  # disagree.
  startComment =
    if cfg.user == "root" then "-c /root: the shell starts in root's home."
    else if startDir == "/" then "-c /: ${cfg.user} has no home other than /, so the shell starts in /."
    else "-c ${startDir}: the shell starts in the home of ${cfg.user}.";
  # The two rendered files are read by the tmux server, which runs as `user`.
  # root keeps what NixOS gives a plain etc entry, so a host that never sets
  # `user` changes nothing; any other account owns them, group read for the
  # reader group, as install.sh does for the plain-systemd path.
  etcOwner = optionalAttrs (cfg.user != "root") {
    user = cfg.user;
    group = cfg.readerGroup;
    mode = "0640";
  };

  envVars = {
    TMUX_SHARE_DIR = cfg.directory;
    TMUX_SHARE_SESSION = cfg.sessionName;
    TMUX_SHARE_SOCK = sock;
    TMUX_SHARE_LOG = transcript;
    TMUX_SHARE_LOCK = lock;
    TMUX_SHARE_NOTREADY_MARKER = notReadyMarker;
    TMUX_SHARE_REBUILD = rebuildMarker;
    TMUX_SHARE_STAMP = stamp;
    TMUX_SHARE_TMUX = "${pkgs.tmux}/bin/tmux";
    TMUX_SHARE_TIMEOUT = "${pkgs.coreutils}/bin/timeout";
    TMUX_SHARE_MAX_BYTES = toString cfg.maxBytes;
    TMUX_SHARE_LIBDIR = libDir;
    TMUX_SHARE_GROUP = cfg.readerGroup;
  } // optionalAttrs (cfg.readerUser != null) {
    TMUX_SHARE_READER = cfg.readerUser;
    # Named only when it is not root, so the verifier's default (root) and the
    # env file of a host that never sets `user` stay as they were.
  } // optionalAttrs (cfg.user != "root") {
    TMUX_SHARE_USER = cfg.user;
  };

  # Shell-quoted KEY='value' lines, as tmux-share-render's `paths` mode writes
  # them. Every value has passed the assertions below, so none holds a quote.
  envText = ''
    # Generated by the tmux-share NixOS module. Read by the units through
    # EnvironmentFile= and sourced by the operator's commands.
  '' + lib.concatStrings (lib.mapAttrsToList (k: v: "${k}='${v}'\n") envVars);

  tmuxConfText = lib.concatStrings [
    ''
      # tmux configuration for the dedicated tmux-share server (generated).
      # TRAP: exit-empty on. Without it, a server whose last session ends stays
      # up half-alive with nothing to monitor, and systemd never sees it stop.
      set -g exit-empty on
    ''
    (lib.optionalString (cfg.shell != null) ''

      # TRAP: default-shell. Without it the operator gets root's login shell from
      # the account database. -g is deliberate: this server is dedicated to
      # tmux-share, so a global option cannot leak into anyone else's tmux.
      set -g default-shell ${cfg.shell}
    '')
    ''

      # Created at server start, so the transcript tap and the operator's attach
      # always find a session. ${startComment}
      new-session -d -s ${cfg.sessionName} -c ${startDir}
    ''
  ];
in
{
  options.services.tmux-share = {
    enable = mkEnableOption "the tmux-share dedicated tmux server, with its transcript tap, watchdog and trimmer";

    sessionName = mkOption {
      type = types.str;
      default = "tmux-hermes";
      description = ''
        Name of the monitored tmux session. Must match
        ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$: it is written into tmux commands.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = ''
        The account that owns the tmux server, the socket, the transcript, the
        lock and the markers, and that the server, tap and trimmer units run as.
        An account declared in users.users, which this module does not create:
        a unit for an account the host lacks fails at boot, so evaluation
        refuses one. The lock is owned by the account and its primary group
        (users.users.<user>.group), so that must be set. This account and root
        are the accounts tmux-share is meant for. It must not be readerUser.
      '';
    };

    readerGroup = mkOption {
      type = types.str;
      default = "tmux-share";
      description = ''
        Group that may read the transcript and traverse the runtime directory.
        The module creates it. It holds traverse and read access only, never write.
      '';
    };

    readerUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        An existing account that reads the transcript; the module adds it to
        readerGroup. The module does not create the account. It cannot know which
        account the operator uses for tmux-share beyond `user`, so it
        forbids root and `user`. null adds nobody: grant access later with
        `usermod -aG <group> <user>`.
      '';
    };

    directory = mkOption {
      type = types.str;
      default = "/run/tmux-share";
      description = ''
        Runtime directory holding the socket, the transcript and the markers.
        Absolute, no "..", and only the characters A-Za-z0-9_./- with no trailing "/".
      '';
    };

    socketName = mkOption {
      type = types.str;
      default = "tmux.sock";
      description = "File name of the tmux server socket, inside directory.";
    };

    transcriptName = mkOption {
      type = types.str;
      default = "transcript.log";
      description = "File name of the transcript, inside directory.";
    };

    maxBytes = mkOption {
      type = types.int;
      default = 2097152;
      description = "Transcript size bound in bytes; the trimmer keeps the newest maxBytes. Positive.";
    };

    shell = mkOption {
      type = types.nullOr types.str;
      default = "${pkgs.fish}/bin/fish";
      description = ''
        Shell the operator gets inside the session (tmux default-shell). null leaves
        tmux's default, which is the login shell of `user` from the account database.
        An absolute path with only A-Za-z0-9_./- characters.
      '';
    };

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "the tmux-share flake's packages.<system>.default";
      description = "The tmux-share scripts. Installs the attach, verify and render commands on PATH.";
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = matches sessionRe cfg.sessionName;
          message = "services.tmux-share.sessionName must match ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$; it is written into tmux commands, where a ';' or a quote would run as a tmux command.";
        }
        {
          assertion = cfg.readerUser != "root";
          message = "services.tmux-share.readerUser must not be \"root\": the reader is read-only by design, and root already reads everything. The account in services.tmux-share.user is refused as a reader by a separate assertion.";
        }
        {
          assertion = cfg.readerUser == null || matches nameRe cfg.readerUser;
          message = "services.tmux-share.readerUser must be a plain account name ([A-Za-z0-9_][A-Za-z0-9_.-]*).";
        }
        {
          assertion = matches nameRe cfg.user;
          message = "services.tmux-share.user must be a plain account name ([A-Za-z0-9_][A-Za-z0-9_.-]*): it is written into tmpfiles rules and unit files, where a space or a ';' would change what they mean.";
        }
        {
          # Units and tmpfiles rules name this account, and both fail at boot for
          # one the host does not have. install.sh refuses the same case.
          assertion = cfg.user == "root" || builtins.hasAttr cfg.user config.users.users;
          message = "services.tmux-share.user (\"${cfg.user}\") must be root or an account declared in users.users: the units run as it and tmpfiles rules are owned by it, and both fail at boot, not at evaluation, for an account the host does not have. Declare it with users.users.${cfg.user} = { isNormalUser = true; ... };";
        }
        {
          assertion = userGroup != "";
          message = "users.users.${cfg.user}.group is empty, so the primary group of services.tmux-share.user cannot be determined: the lock file is owned by that group. Set users.users.${cfg.user}.group (a normal user gets \"users\" by default).";
        }
        {
          assertion = cfg.readerUser == null || cfg.user != cfg.readerUser;
          message = "services.tmux-share.user must not be the readerUser: the reader gets the transcript and never the socket, and the account that owns the server can drive its shell. The operator and the reader have to be different accounts.";
        }
        {
          # "/" is the fallback for an account NixOS has no home for; the
          # session's start directory is written into the tmux configuration.
          assertion = startDir == "/" || matches pathRe startDir;
          message = "the home of services.tmux-share.user (users.users.<user>.home) must be an absolute path with only A-Z a-z 0-9 _ . / - characters: it is written into the tmux configuration, where a ';' would start another tmux command.";
        }
        {
          assertion = matches nameRe cfg.readerGroup;
          message = "services.tmux-share.readerGroup must be a plain group name ([A-Za-z0-9_][A-Za-z0-9_.-]*).";
        }
        {
          assertion = lib.hasPrefix "/" cfg.directory && !(lib.hasInfix ".." cfg.directory);
          message = "services.tmux-share.directory must be an absolute path (starting with /) with no \"..\" in it.";
        }
        {
          assertion = matches pathRe cfg.directory;
          message = "services.tmux-share.directory may use only A-Z a-z 0-9 _ . / - and must not end in '/'; the scripts refuse any other path.";
        }
        {
          assertion = matches nameRe cfg.socketName;
          message = "services.tmux-share.socketName must be a plain file name (no '/').";
        }
        {
          assertion = matches nameRe cfg.transcriptName;
          message = "services.tmux-share.transcriptName must be a plain file name (no '/').";
        }
        {
          # Twelve digits at most, the renderer's own limit.
          assertion = cfg.maxBytes > 0 && cfg.maxBytes < 1000000000000;
          message = "services.tmux-share.maxBytes must be a positive integer below 10^12.";
        }
        {
          assertion = cfg.shell == null || matches pathRe cfg.shell;
          message = "services.tmux-share.shell must be null or an absolute path with only A-Z a-z 0-9 _ . / - characters: it is written into the tmux configuration, where a ';' would start another tmux command.";
        }
      ];
    }

    (mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];

      # The reader group. The sysusers rule declares only this group; the reader
      # account is never created here (see the sysusers file).
      users.groups.${cfg.readerGroup} = { };

      # Adding the reader to the group is what grants read access to the
      # transcript. The account must already be declared on the host.
      users.users = optionalAttrs (cfg.readerUser != null) {
        ${cfg.readerUser}.extraGroups = [ cfg.readerGroup ];
      };

      environment.etc."tmux-share/tmux.conf" = { text = tmuxConfText; } // etcOwner;
      environment.etc."tmux-share/env" = { text = envText; } // etcOwner;

      # TRAP: the rules fix every mode. A "-" mode takes the creator's umask, so
      # the boundary would depend on who ran tmpfiles. Ages are "-" so /run
      # cleanup never removes a live file.
      systemd.tmpfiles.rules = [
        # The runtime directory: traverse for the group, never list. 0710 keeps
        # the reader from enumerating what else is in it. It belongs to `user`,
        # so the markers the scripts create inside it do too.
        "d ${cfg.directory} 0710 ${cfg.user} ${cfg.readerGroup} - -"
        # The transcript: group read only. No group write, so the reader cannot
        # alter or truncate the record.
        "f ${transcript} 0640 ${cfg.user} ${cfg.readerGroup} - -"
        # The lock: `user` only, and not group-readable. flock needs only read
        # access, so a reader who could open it could stall the taps. The group is
        # the account's primary group, which exists by construction; a group
        # named after the account usually does not.
        "f ${lock} 0600 ${cfg.user} ${userGroup} - -"
        # TRAP: no rule for the socket. tmux creates it itself, mode 0600 and
        # owned by `user`. A rule that pre-created it would have to pick a mode,
        # and any mode wider than tmux's own would undo the boundary.
      ];

      systemd.services.tmux-share-server = {
        description = "tmux-share dedicated tmux server";
        # TRAP: order after tmpfiles. It creates the 0710 directory the socket
        # lives in; without the ordering the server can start before it exists.
        after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = runAs // {
          # The tmux server with -D stays in the foreground, and systemd tracks it.
          Type = "simple";
          # TRAP: the leading "-" lets the server start without the env file.
          EnvironmentFile = "-${envFile}";
          # The socket and config paths are the contract defaults, as in the template.
          ExecStart = "${pkgs.tmux}/bin/tmux -D -S ${sock} -f ${tmuxConf}";
          # TRAP: the leading "-" on ExecStartPost. A tap that fails to attach
          # must not take the operator's live session down with it: a failing
          # ExecStartPost without "-" marks the unit failed and stops the server.
          # tap-start runs right after fork, so it waits for the session itself.
          ExecStartPost = "-${bin "tmux-share-tap-start"}";
          # TRAP: no UMask. The server's umask becomes the umask of every shell the
          # operator opens inside it. The module never sets one.
          # TRAP: no RuntimeDirectory. It would recreate /run/tmux-share as 0755 at
          # start, undoing the 0710 that tmpfiles set.
          # on-failure, not always: a clean exit (last session gone, exit-empty)
          # stays stopped instead of looping.
          Restart = "on-failure";
          # Do not spin if the server dies at once.
          RestartSec = 2;
        };
      };

      systemd.services.tmux-share-tap = {
        description = "tmux-share watchdog (keeps the transcript tap attached)";
        # Ordered behind the server, but no Requires/Wants: a pass never starts or
        # restarts the server.
        after = [ "tmux-share-server.service" ];
        serviceConfig = runAs // {
          # TRAP: oneshot with RemainAfterExit=no. A oneshot left active is never
          # started again by its timer, so the watchdog would run once and stop.
          Type = "oneshot";
          RemainAfterExit = false;
          # No "-": a missing env file must fail the pass loudly, not run it on defaults.
          EnvironmentFile = envFile;
          ExecStart = bin "tmux-share-watchdog";
        };
      };

      systemd.timers.tmux-share-tap = {
        description = "Run the tmux-share watchdog every 20 seconds";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # TRAP: OnBootSec alongside OnUnitActiveSec. OnUnitActiveSec alone never
          # fires for a unit that has not run yet.
          OnBootSec = "20s";
          OnUnitActiveSec = "20s";
          # TRAP: AccuracySec=1s. systemd's default is one minute, which stretches
          # "every 20 seconds" to as much as 80.
          AccuracySec = "1s";
        };
      };

      systemd.services.tmux-share-trim = {
        description = "tmux-share transcript trimmer";
        after = [ "tmux-share-server.service" ];
        serviceConfig = runAs // {
          # TRAP: the same oneshot rule as the watchdog (RemainAfterExit=no).
          Type = "oneshot";
          RemainAfterExit = false;
          EnvironmentFile = envFile;
          ExecStart = bin "tmux-share-trim";
        };
      };

      systemd.timers.tmux-share-trim = {
        description = "Run the tmux-share transcript trimmer every five minutes";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "5min";
          # TRAP: AccuracySec=1s, the same default-of-one-minute trap as the watchdog.
          AccuracySec = "1s";
        };
      };
    })
  ];
}
