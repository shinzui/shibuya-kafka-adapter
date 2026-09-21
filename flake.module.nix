# flake.module.nix — project-specific flake-parts customizations.
#
# UNMANAGED: seihou never regenerates or overwrites this file, so edits here
# survive nix-haskell-flake template upgrades without conflict. flake.nix imports
# it automatically when present. See flake.module.nix.example for the full option
# reference.
{ lib, ... }:
{
  perSystem = { pkgs, ... }: {
    # librdkafka: the C library the project's Kafka client links against (needs
    # pkg-config, which the managed dev shell already provides). Previously listed
    # directly in nix/haskell.nix; relocated here so the managed file stays
    # pristine across upgrades.
    haskellProject.extraDevPackages = [ pkgs.rdkafka ];

    # The repository is a multi-package Cabal project, while the published
    # default output is the adapter library. Pin the fast-moving project
    # dependencies and their compatibility set to authoritative Hackage
    # releases: nixpkgs still selects pre-upgrade Kafka packages and an older
    # Shibuya.
    packages.default = lib.mkForce (
      let
        haskellPackages = pkgs.haskell.packages.ghc9124.override {
          overrides = hself: hsuper: {
            hw-kafka-streamly = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "hw-kafka-streamly";
                ver = "0.2.0.0";
                sha256 = "06jibai4zpn736v3whngjprplzzjad9np42r5hv1s0mv1xhls39v";
              }
              { });
            kafka-effectful = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "kafka-effectful";
                ver = "0.3.1.0";
                sha256 = "1nnq0q35shb6nbxgjmf8kyip9a6pq01b7mcl6c1pd5lkr6bi79k9";
              }
              { });
            hs-opentelemetry-api-types = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "hs-opentelemetry-api-types";
                ver = "1.0.0.0";
                sha256 = "03rgj71r7k66iwz6vc2z5q7d1s61d4jwp6ra619qwmr5bkiqy77l";
              }
              { });
            hs-opentelemetry-api = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "hs-opentelemetry-api";
                ver = "1.0.0.0";
                sha256 = "183zvzsvciwapm4ik6vxybmf8zj3d1nhn4ywnx3fsyimrgs67s08";
              }
              { });
            hs-opentelemetry-semantic-conventions = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "hs-opentelemetry-semantic-conventions";
                ver = "1.40.0.0";
                sha256 = "0ag655nrw0mhimlv3mwwki4p2bd6mqn168hbik4rcxzbsksh5hpd";
              }
              { });
            hs-opentelemetry-propagator-w3c = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "hs-opentelemetry-propagator-w3c";
                ver = "1.0.0.0";
                sha256 = "0yr3vcs4ynw25lp8cmj10zdcn3q2596z4v0sx9j5828v3x7pdix7";
              }
              { });
            streamly = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "streamly";
                ver = "0.11.1";
                sha256 = "1dxyhq8m9fr3ghpmxkh6bc37fd4f1048xckjrlpp6ybvlg0lq7g2";
              }
              { });
            streamly-core = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "streamly-core";
                ver = "0.3.1";
                sha256 = "1bk9m7h0kar6nipq36kxdhxh9g48v5828qcygxpcjdh6pqipxn4k";
              }
              { });
            shibuya-core = pkgs.haskell.lib.dontCheck (hself.callHackageDirect
              {
                pkg = "shibuya-core";
                ver = "0.9.0.3";
                sha256 = "1bh2dhpzcmzsz0qagqrhhsfkpkd8k3fypl5y5h8fzj02fw67yiy3";
              }
              { });
            # unicode-data-0.6's tests compare against GHC 9.12.4's newer
            # Unicode tables and fail despite the library building correctly.
            unicode-data = pkgs.haskell.lib.dontCheck hsuper.unicode-data;
          };
        };
      in
      # The repository tests exercise lifecycle APIs from the unreleased
        # Shibuya candidate and run in the cross-repository Cabal gate. Keep the
        # portable flake on released Hackage inputs and build the distributable
        # library here until that candidate has been published.
      pkgs.haskell.lib.dontCheck (
        haskellPackages.callCabal2nix "shibuya-kafka-adapter" ./shibuya-kafka-adapter { }
      )
    );
  };
}
