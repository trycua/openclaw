# Example: Congruent NixOS Service Definition
#
# This example shows the recommended pattern for defining systemd services
# that automatically restart when code changes are deployed.
#
# Key principle: ExecStart should reference a Nix store path (directly or
# via derivation interpolation) so that systemd sees unit file changes
# when the derivation changes.

{ config, lib, pkgs, ... }:

let
  # Your application derivation - hash changes when code changes
  myApp = pkgs.callPackage ./my-app.nix { };

  # Wrapper script pattern (if runtime config injection needed)
  appWrapper = pkgs.writeShellScript "my-app-wrapper" ''
    # Load runtime config
    if [[ -f /var/lib/my-app/.env ]]; then
      set -a
      source /var/lib/my-app/.env
      set +a
    fi

    # Run from store path - this is the key for congruence!
    cd ${myApp}/lib/my-app
    exec ${pkgs.nodejs}/bin/node server.js "$@"
  '';

in {
  # Option 1: Direct store path reference (RECOMMENDED)
  # - Simplest approach
  # - ExecStart path changes when derivation changes
  # - No restartTriggers needed
  systemd.services.my-app-simple = {
    description = "My App (Direct Store Path)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "postgresql.service" ];
    wants = [ "network-online.target" ];
    requires = [ "postgresql.service" ];

    serviceConfig = {
      # Store path in ExecStart = automatic restarts on code changes
      ExecStart = "${myApp}/bin/my-app-server";
      WorkingDirectory = "/var/lib/my-app";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Option 2: Wrapper script pattern
  # - Use when runtime config injection is needed
  # - Wrapper script path changes when myApp changes
  # - Still no explicit restartTriggers needed
  systemd.services.my-app-wrapper = {
    description = "My App (Wrapper Script)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      # Wrapper references ${myApp} -> path changes when code changes
      ExecStart = "${appWrapper}";
      WorkingDirectory = "/var/lib/my-app";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Option 3: Explicit restartTriggers (FALLBACK ONLY)
  # - Use only when store path reference isn't possible
  # - Fragile: easy to forget the trigger
  # - Document why this pattern is necessary
  systemd.services.my-app-legacy = {
    description = "My App (Legacy Pattern - Avoid If Possible)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];

    # IMPORTANT: Must include ALL derivations that affect runtime behavior
    restartTriggers = [
      myApp                              # Application code
      config.environment.etc."my-app/config.json".source  # Config file
    ];

    serviceConfig = {
      # WARNING: Runtime path - relies on restartTriggers for restarts
      ExecStart = "${pkgs.nodejs}/bin/node /var/lib/my-app/dist/server.js";
      WorkingDirectory = "/var/lib/my-app";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Setup: Ensure runtime directory exists
  systemd.tmpfiles.rules = [
    "d /var/lib/my-app 0750 my-app my-app -"
  ];
}
