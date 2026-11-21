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
# The names of the five units follow services.tmux-share.unitPrefix. The
# default prefix is the one the templates in systemd/ use, so a host that sets
# nothing renders the units it rendered before.
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

  # The name of the server unit, from the prefix. The default prefix is the
  # one the templates in systemd/ use, so a host that sets nothing renders the
  # same unit names; a host whose deployment already runs under another name
  # says so, and the units it manages are renamed with it. The watchdog and
  # the trimmer are ordered behind this one.
  serverUnit = "${cfg.unitPrefix}-server.service";

  # The PATH the session's shells get, the way tmux's set-environment takes
  # it: one string, the directories joined by ":". Every entry has passed the
  # assertion below, so none of them holds a quote, a space or a semicolon.
  sessionPathText =
    if cfg.sessionPath == null then ""
    else lib.concatStringsSep ":" cfg.sessionPath;

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
    (lib.optionalString (cfg.terminal != null) ''

      # TRAP: default-terminal. The type the shells announce decides what they
      # can draw: a type the host's terminfo does not have means no colours
      # and no keypad in every pane the operator opens. -g is deliberate, as
      # above: this server is dedicated to tmux-share.
      set -g default-terminal ${cfg.terminal}
    '')
    (lib.optionalString (cfg.historyLimit != null) ''

      # TRAP: history-limit. The scroll-back buffer is what the operator reads
      # after a long command; tmux's own 2000 lines are often shorter than the
      # output they want to scroll back through, and a bigger buffer costs
      # memory in every pane they open.
      set -g history-limit ${toString cfg.historyLimit}
    '')
    (lib.optionalString (cfg.serverAccessReadOnly != null) ''

      # TRAP: server-access. Defence in depth, and only that: while the socket
      # is owner-only this entry cannot be reached, and it does not stop
      # send-keys from an account that can already connect to the socket. It
      # says what the server would allow if the socket's mode were widened.
      server-access -a -r ${cfg.serverAccessReadOnly}
    '')
    (lib.optionalString (cfg.sessionPath != null) ''

      # TRAP: the session's PATH. The shells inside the session inherit the
      # environment of the account running the server, which is not the
      # operator's login PATH, so a session that cannot find the operator's
      # tools is a session the operator has to fix by hand every time. The
      # value is the whole PATH, so it replaces the inherited one instead of
      # adding to it, and it is set before the session is created so that the
      # session's shells get it.
      set-environment -g PATH "${sessionPathText}"
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

    unitPrefix = mkOption {
      type = types.str;
      default = "tmux-share";
      description = ''
        Prefix of the names of the five systemd units: <prefix>-server.service,
        <prefix>-tap.service, <prefix>-tap.timer, <prefix>-trim.service and
        <prefix>-trim.timer. The default keeps the names the templates in
        systemd/ use, so a host that sets nothing renders the units it
        rendered before; a host whose deployment already runs the feature
        under another name (the live host uses "tmux-admin") sets this to keep
        its own names. The software is tmux-share whatever the units are
        called.
        A plain name ([A-Za-z0-9_][A-Za-z0-9_.-]*): it names systemd units,
        where a space or a ';' would change what they mean.
      '';
    };

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

    terminal = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Terminal type the shells inside the session announce (tmux
        default-terminal), for example "tmux-256color". null writes nothing,
        so tmux keeps its own default: this module has never written a
        default-terminal, and writing one now would change the rendered file
        of every deployment that exists. The live host sets "tmux-256color".
        A plain name ([A-Za-z0-9_][A-Za-z0-9_.-]*): it is written into the tmux
        configuration, where a ';' would start another tmux command.
      '';
    };

    historyLimit = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Number of lines the session's scroll-back buffer keeps (tmux
        history-limit). null writes nothing, so tmux keeps its own default of
        2000 lines: this module has never written a history-limit, and writing
        one now would change the rendered file of every deployment that
        exists. The live host sets 2000, which is that same default.
        A positive integer: the option names a bound on the scroll-back
        buffer, and zero is not a bound.
      '';
    };

    sessionPath = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        PATH the shells inside the session get, as a list of absolute
        directories, for example [ "/usr/local/bin" "/usr/bin" "/bin" ]. The
        module writes them joined by ":" into the tmux configuration, as
        "set-environment -g PATH", so the session's shells get exactly that
        PATH and not the one the account running the server happens to have.
        null writes nothing, and the shells inherit the server's PATH as they
        do today. The live host sets the PATH its operators expect.
        Every entry must be an absolute path with only A-Z a-z 0-9 _ . / -
        characters: the value is written into the tmux configuration, where a
        ';' would start another tmux command.
      '';
    };

    serverAccessReadOnly = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        An account tmux's server-access list gets read-only access to: the
        module writes "server-access -a -r <account>" into the tmux
        configuration. Defence in depth, and nothing more: while the socket is
        owner-only the entry cannot be reached, and it does not stop
        send-keys from an account that can already connect to the socket. It
        says what the server would allow if the socket's mode were ever
        widened; it is not a second boundary, and it does not replace the
        socket's mode. null writes no entry at all. The live host names the
        account that may attach read-only.
        A plain account name ([A-Za-z0-9_][A-Za-z0-9_.-]*), and not the
        account that owns the server: an account cannot be both the owner of
        the socket and a read-only guest of it.
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
          # The prefix names the five units. A unit name systemd cannot make
          # is a unit that never starts, and the operator is left with a
          # feature that is not running and no error.
          assertion = matches nameRe cfg.unitPrefix;
          message = "services.tmux-share.unitPrefix must be a plain name ([A-Za-z0-9_][A-Za-z0-9_.-]*): it names the systemd units (<prefix>-server.service and the rest), where a space or a ';' would change what they mean.";
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
        {
          assertion = cfg.terminal == null || matches nameRe cfg.terminal;
          message = "services.tmux-share.terminal must be null or a plain terminal name ([A-Za-z0-9_][A-Za-z0-9_.-]*): it is written into the tmux configuration, where a ';' would start another tmux command.";
        }
        {
          assertion = cfg.historyLimit == null || cfg.historyLimit > 0;
          message = "services.tmux-share.historyLimit must be null or a positive integer: the option names a bound on the scroll-back buffer, and zero is not a bound; the module writes the value into the tmux configuration.";
        }
        {
          # Every entry of the PATH, one by one. The value is joined and
          # written into the tmux configuration as one string, so a single
          # entry with a ';' in it would start another tmux command.
          assertion = cfg.sessionPath == null || (cfg.sessionPath != [] && lib.all (p: matches pathRe p) cfg.sessionPath);
          message = "services.tmux-share.sessionPath must be null or a non-empty list of absolute paths with only A-Z a-z 0-9 _ . / - characters: the value is written into the tmux configuration, where a ';' would start another tmux command.";
        }
        {
          assertion = cfg.serverAccessReadOnly == null || matches nameRe cfg.serverAccessReadOnly;
          message = "services.tmux-share.serverAccessReadOnly must be null or a plain account name ([A-Za-z0-9_][A-Za-z0-9_.-]*): it is written into the tmux configuration, where a ';' would start another tmux command.";
        }
        {
          # The owner of the server is already allowed everything the server
          # allows; giving it a read-only entry as well says nothing and
          # hides the one account that must never be a guest.
          assertion = cfg.serverAccessReadOnly == null || cfg.serverAccessReadOnly != cfg.user;
          message = "services.tmux-share.serverAccessReadOnly must not be the account that owns the server (services.tmux-share.user): an account cannot be both the owner of the socket and a read-only guest of it.";
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

      systemd.services."${cfg.unitPrefix}-server" = {
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

      systemd.services."${cfg.unitPrefix}-tap" = {
        description = "tmux-share watchdog (keeps the transcript tap attached)";
        # Ordered behind the server, but no Requires/Wants: a pass never starts or
        # restarts the server.
        after = [ serverUnit ];
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

      systemd.timers."${cfg.unitPrefix}-tap" = {
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

      systemd.services."${cfg.unitPrefix}-trim" = {
        description = "tmux-share transcript trimmer";
        after = [ serverUnit ];
        serviceConfig = runAs // {
          # TRAP: the same oneshot rule as the watchdog (RemainAfterExit=no).
          Type = "oneshot";
          RemainAfterExit = false;
          EnvironmentFile = envFile;
          ExecStart = bin "tmux-share-trim";
        };
      };

      systemd.timers."${cfg.unitPrefix}-trim" = {
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
