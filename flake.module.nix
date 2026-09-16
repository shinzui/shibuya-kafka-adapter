# flake.module.nix — project-specific flake-parts customizations.
#
# UNMANAGED: seihou never regenerates or overwrites this file, so edits here
# survive nix-haskell-flake template upgrades without conflict. flake.nix imports
# it automatically when present. See flake.module.nix.example for the full option
# reference.
{ ... }:
{
  perSystem = { pkgs, ... }: {
    # librdkafka: the C library the project's Kafka client links against (needs
    # pkg-config, which the managed dev shell already provides). Previously listed
    # directly in nix/haskell.nix; relocated here so the managed file stays
    # pristine across upgrades.
    haskellProject.extraDevPackages = [ pkgs.rdkafka ];
  };
}
