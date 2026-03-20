# Example: Congruent Gateway Service
#
# This is how nanoclaw-gateway should be structured for automatic
# restarts on code deploys, without needing manual restartTriggers.

{ config, lib, pkgs, ... }:

let
  # The gateway application - built from source
  nanoclawApp = pkgs.buildNpmPackage {
    pname = "nanoclaw";
    version = "0.1.0";
    src = ./..;  # Point to your source

    npmDepsHash = "sha256-...";  # Lock deps for reproducibility

    buildPhase = ''
      npm run build
    '';

    installPhase = ''
      mkdir -p $out/lib/nanoclaw $out/bin

      cp -r dist/* $out/lib/nanoclaw/
      cp -r node_modules $out/lib/nanoclaw/

      # Create wrapper script that references the store path
      cat > $out/bin/nanoclaw-gateway <<EOF
      #!${pkgs.bash}/bin/bash
      cd $out/lib/nanoclaw
      exec ${pkgs.nodejs}/bin/node gateway.js "\$@"
      EOF
      chmod +x $out/bin/nanoclaw-gateway
    '';
  };

in {
  # RECOMMENDED: Gateway with direct store path reference
  systemd.services.nanoclaw-gateway = {
    description = "Nanoclaw Gateway";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "postgresql.service" "nanoclaw-secrets.service" ];
    wants = [ "network-online.target" ];
    requires = [ "postgresql.service" ];

    # Health check endpoint for dependency tracking
    serviceConfig = {
      # KEY: This path changes when nanoclawApp changes
      # -> systemd sees unit file change -> automatic restart
      ExecStart = "${nanoclawApp}/bin/nanoclaw-gateway";

      # Runtime data location (database, logs, sessions)
      WorkingDirectory = "/var/lib/nanoclaw";

      Restart = "always";
      RestartSec = 5;
      KillMode = "process";

      # Security hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/nanoclaw" ];
    };

    # Environment from secrets service (runtime)
    environment = {
      NODE_ENV = "production";
      # Secrets loaded from /var/lib/nanoclaw/.env at runtime
    };
  };

  # Secrets sync service (polls external secret store)
  systemd.services.nanoclaw-secrets = {
    description = "Nanoclaw Secrets Sync";
    wantedBy = [ "multi-user.target" ];
    before = [ "nanoclaw-gateway.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "sync-secrets" ''
        # Fetch secrets from AWS Secrets Manager / Vault / etc.
        # Write to /var/lib/nanoclaw/.env
        # Restart gateway if secrets changed
        aws secretsmanager get-secret-value \
          --secret-id nanoclaw/production \
          --query SecretString \
          --output text > /var/lib/nanoclaw/.env.new

        if ! cmp -s /var/lib/nanoclaw/.env /var/lib/nanoclaw/.env.new; then
          mv /var/lib/nanoclaw/.env.new /var/lib/nanoclaw/.env
          systemctl restart nanoclaw-gateway || true
        else
          rm /var/lib/nanoclaw/.env.new
        fi
      ''}";
    };
  };

  # Timer for periodic secrets sync
  systemd.timers.nanoclaw-secrets = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  # Database migrations (idempotent, runs before gateway)
  systemd.services.nanoclaw-migrate = {
    description = "Nanoclaw Database Migrations";
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql.service" ];
    before = [ "nanoclaw-gateway.service" ];

    # Migrations should re-run when schema changes
    # Store path reference ensures this happens automatically
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${nanoclawApp}/bin/nanoclaw-migrate";
    };
  };
}
