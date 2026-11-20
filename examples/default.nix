# Example host configuration for tmux-share.
#
# Use it from a flake that has tmux-share as an input:
#
#   nixosConfigurations.host = nixpkgs.lib.nixosSystem {
#     modules = [ tmux-share.nixosModules.default ./examples/default.nix ];
#   };
#
# The flake's module-renders check also evaluates this file.
{ ... }:
{
  services.tmux-share = {
    enable = true;
    # The reader account. On a real host it already exists: name it here and
    # drop the account declarations below.
    readerUser = "hermes-reader";
  };

  # Declared only so this example evaluates on its own.
  users.groups.hermes-reader = { };
  users.users.hermes-reader = {
    isSystemUser = true;
    group = "hermes-reader";
  };
}
