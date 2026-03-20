# NixOS Congruent Deployments

This guide explains how to maintain deployment congruence when running OpenClaw services on NixOS.

## The Problem: Silent Deployment Failures

When NixOS services use runtime paths (like `/var/lib/app/dist`) in `ExecStart` instead of Nix store paths, code changes can deploy without the service restarting:

```nix
# Divergent pattern - service won't restart on code changes
systemd.services.my-gateway = {
  serviceConfig = {
    ExecStart = "${pkgs.nodejs}/bin/node /var/lib/app/dist/gateway.js";
  };
};
```

**Why this fails:**
1. Code changes create a new Nix derivation in `/nix/store/xyz-app/`
2. A separate step copies code to `/var/lib/app/dist`
3. systemd sees no change to the unit file (ExecStart unchanged)
4. Service keeps running old code

## Solution: Direct Store Path References

Make `ExecStart` reference the Nix derivation directly so systemd sees unit file changes:

```nix
# Congruent pattern - automatic restarts on code changes
systemd.services.my-gateway = {
  serviceConfig = {
    # Store path changes when code changes -> unit file changes -> restart
    ExecStart = "${myApp}/bin/gateway";

    # Runtime data still goes to /var/lib (database, logs, etc.)
    WorkingDirectory = "/var/lib/my-app";
  };
};
```

**How it works:**
1. `myApp` is a Nix derivation at `/nix/store/abc123-myapp/`
2. When code changes, derivation hash changes -> new store path
3. NixOS regenerates unit file with new path
4. systemd sees unit file change -> triggers restart
5. No manual `restartTriggers` needed

## When restartTriggers Are Still Needed

If you cannot reference the store path directly (e.g., complex runtime config injection), use explicit `restartTriggers`:

```nix
systemd.services.my-gateway = {
  # Explicitly track the derivation for restarts
  restartTriggers = [ myApp ];

  serviceConfig = {
    ExecStart = "${pkgs.nodejs}/bin/node /var/lib/app/dist/gateway.js";
  };
};
```

**Warning:** This pattern is fragile - forgetting `restartTriggers` on any service creates silent deployment failures.

## Alternative: Version in Environment

Force unit file regeneration by embedding the version in the environment:

```nix
systemd.services.my-gateway = {
  restartIfChanged = true;  # Default, but make explicit

  # This changes when derivation changes, forcing unit regeneration
  environment.APP_VERSION = "${myApp}";

  serviceConfig = {
    ExecStart = "${pkgs.nodejs}/bin/node /var/lib/app/dist/gateway.js";
  };
};
```

## Wrapper Script Pattern

For services needing runtime configuration, use a wrapper script that references the store:

```nix
let
  gatewayWrapper = pkgs.writeShellScript "gateway-wrapper" ''
    cd ${myApp}/lib/app
    exec ${pkgs.nodejs}/bin/node gateway.js "$@"
  '';
in
systemd.services.my-gateway = {
  serviceConfig = {
    # Wrapper script path changes when myApp changes
    ExecStart = "${gatewayWrapper}";
    WorkingDirectory = "/var/lib/my-app";
  };
};
```

## CI Enforcement

Add the lint script to your CI pipeline to catch divergent patterns:

```yaml
# .github/workflows/nix-lint.yml
- name: Check deployment congruence
  run: ./scripts/lint-nix-systemd-congruence.sh
```

## Verification

After deploying, verify the service restarted:

```bash
# Check service restarted within last 60 seconds
systemctl show my-gateway --property=ActiveEnterTimestamp

# View recent logs
journalctl -u my-gateway -n 20 --since "1 minute ago"
```

## Checklist

Before adding a new NixOS service:

- [ ] `ExecStart` references a Nix store path (directly or via wrapper)
- [ ] OR `restartTriggers` includes the application derivation
- [ ] OR version/hash is embedded in environment
- [ ] Service has health check endpoint
- [ ] Dependencies declared with `after` and `requires`

## See Also

- [NixOS Manual: Service Management](https://nixos.org/manual/nixos/stable/#sec-systemd)
- [Nix Pills: Derivations](https://nixos.org/guides/nix-pills/our-first-derivation)
