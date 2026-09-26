#!/usr/bin/env python3
"""Load and validate TVGuard machine target scope.

config/tvguard.conf (or TVGUARD_CONFIG) is the only machine-specific target
source. Privacy policy files remain network-independent.
"""
import argparse
import ipaddress
import json
import os
import re
import shlex
import sys

import yaml


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CONFIG = os.path.join(ROOT, "config", "tvguard.conf")
DEFAULT_INSTANCES = os.path.join(ROOT, "config", "privacy-instances.yaml")
LEGACY_TARGET_ALIASES = {
    "SAMSUNG_TVS": "SAMSUNG_IP",
    "LG_TVS": "LG_IP",
    "GOOGLE_TVS": "GOOGLE_TV_IP",
}
_ASSIGNMENT = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


class TargetConfigError(ValueError):
    """Raised when machine target configuration is unsafe or inconsistent."""


class TargetConfig:
    def __init__(self, path, values, tvs, target_lists, vendor_targets):
        self.path = path
        self.values = values
        self.tvs = tuple(tvs)
        self.target_lists = {key: tuple(items) for key, items in target_lists.items()}
        self.vendor_targets = {
            vendor: tuple(items) for vendor, items in vendor_targets.items()
        }


def resolve_config_path(config_path=None, root=ROOT):
    """Resolution order (identical to scripts/_tvguard_env.sh):
      1. $TVGUARD_CONFIG / $TVGUARD_ENV  (test override: throwaway fixture)
      2. $root/.env                       (the single machine-specific file)
      3. $root/config/tvguard.conf        (legacy location, pre-.env machines)
    """
    if config_path is None:
        config_path = os.environ.get("TVGUARD_CONFIG") or os.environ.get("TVGUARD_ENV")
        if not config_path:
            env_file = os.path.join(root, ".env")
            legacy = os.path.join(root, "config", "tvguard.conf")
            if os.path.exists(env_file):
                config_path = env_file
            elif os.path.exists(legacy):
                config_path = legacy
            else:
                raise TargetConfigError(
                    "no machine config found: create .env from .env.example "
                    "(or run bootstrap.sh)"
                )
    if not config_path:
        raise TargetConfigError("TVGUARD_CONFIG is set but empty")
    return os.path.abspath(os.path.expanduser(config_path))


def parse_shell_config(path):
    """Parse the simple KEY=value assignments used by .env / tvguard.conf.

    Handles both quote styles: TVS="a b" (shell) and TVS=a b (dotenv-style
    unquoted). Comments (# ...) and blank lines are skipped."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = list(fh)
    except OSError as exc:
        raise TargetConfigError("cannot read machine config %s: %s" % (path, exc)) from exc

    values = {}
    for lineno, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = _ASSIGNMENT.match(line)
        if not match:
            raise TargetConfigError(
                "%s:%d: expected a KEY=value assignment" % (path, lineno)
            )
        key, raw_value = match.groups()
        lexer = shlex.shlex(raw_value, posix=True)
        lexer.whitespace_split = True
        lexer.commenters = "#"
        try:
            parts = list(lexer)
        except ValueError as exc:
            raise TargetConfigError("%s:%d: %s" % (path, lineno, exc)) from exc
        # With whitespace_split, a quoted list like "a b" yields both parts;
        # an unquoted single value yields one part. Empty ("" or blank) -> "".
        values[key] = " ".join(parts)
    return values


def _validated_ipv4_list(name, items):
    validated = []
    seen = set()
    for item in items:
        try:
            address = ipaddress.ip_address(item)
        except ValueError as exc:
            raise TargetConfigError("%s contains invalid IP address %r" % (name, item)) from exc
        if address.version != 4:
            raise TargetConfigError("%s contains non-IPv4 address %s" % (name, item))
        canonical = str(address)
        if canonical in seen:
            raise TargetConfigError("%s contains duplicate address %s" % (name, canonical))
        seen.add(canonical)
        validated.append(canonical)
    return validated


def _target_items(values, key):
    raw = values.get(key, "").strip()
    source = key
    if not raw and key in LEGACY_TARGET_ALIASES:
        source = LEGACY_TARGET_ALIASES[key]
        raw = values.get(source, "").strip()
    items = raw.split() if raw else []
    if source != key and len(items) > 1:
        raise TargetConfigError("legacy %s must contain at most one address" % source)
    return _validated_ipv4_list(source, items)


def load_target_config(instances, config_path=None, root=ROOT):
    """Load target lists and enforce all machine-scope invariants."""
    path = resolve_config_path(config_path, root=root)
    values = parse_shell_config(path)

    if not isinstance(instances, dict) or not instances:
        raise TargetConfigError("privacy instance registry has no instances")

    registry_keys = {}
    for vendor, vendor_config in instances.items():
        if not isinstance(vendor_config, dict):
            raise TargetConfigError("privacy instance %s must be a mapping" % vendor)
        key = vendor_config.get("targets_key")
        if not isinstance(key, str) or not key:
            raise TargetConfigError("privacy instance %s has no targets_key" % vendor)
        if key in registry_keys:
            raise TargetConfigError(
                "targets_key %s is shared by privacy instances %s and %s"
                % (key, registry_keys[key], vendor)
            )
        registry_keys[key] = vendor

    tvs = _validated_ipv4_list("TVS", values.get("TVS", "").split())
    tv_set = set(tvs)

    target_keys = list(registry_keys)
    for key in LEGACY_TARGET_ALIASES:
        if key not in target_keys:
            target_keys.append(key)

    target_lists = {key: _target_items(values, key) for key in target_keys}
    owners = {}
    for key, targets in target_lists.items():
        outside = sorted(set(targets) - tv_set)
        if outside:
            raise TargetConfigError(
                "%s target(s) not present in TVS: %s" % (key, ", ".join(outside))
            )
        for target in targets:
            if target in owners:
                raise TargetConfigError(
                    "target %s appears in both %s and %s"
                    % (target, owners[target], key)
                )
            owners[target] = key

    vendor_targets = {
        vendor: target_lists[vendor_config["targets_key"]]
        for vendor, vendor_config in instances.items()
    }
    return TargetConfig(path, values, tvs, target_lists, vendor_targets)


def validate_resolved_target_scopes(
    instances, target_config, resolved, active_vendors, effective_tvs=None
):
    """Validate active resolved scopes before firewall or Pi-hole use."""
    resolved_vendors = resolved.get("vendors") if isinstance(resolved, dict) else None
    if not isinstance(resolved_vendors, dict):
        raise TargetConfigError("resolved policy has no vendors mapping")

    configured_tvs = set(target_config.tvs)
    if effective_tvs is None:
        effective_tv_set = configured_tvs
    else:
        effective_tv_set = set(_validated_ipv4_list("effective TVS", effective_tvs))

    scopes = {}
    owners = {}
    for vendor in active_vendors:
        if vendor not in instances:
            raise TargetConfigError("active privacy vendor %s is not registered" % vendor)
        vendor_result = resolved_vendors.get(vendor)
        if not isinstance(vendor_result, dict):
            raise TargetConfigError("resolved policy has no vendor section for %s" % vendor)
        raw_targets = vendor_result.get("applies_to", [])
        if not isinstance(raw_targets, list):
            raise TargetConfigError("resolved targets for %s must be a list" % vendor)
        targets = _validated_ipv4_list(
            "resolved targets for %s" % vendor, [str(item) for item in raw_targets]
        )
        if not targets:
            raise TargetConfigError(
                "privacy vendor %s is active but its resolved target list is empty" % vendor
            )

        outside = sorted(set(targets) - configured_tvs)
        if outside:
            raise TargetConfigError(
                "active resolved targets for %s are not in configured TVS: %s"
                % (vendor, ", ".join(outside))
            )
        outside_effective = sorted(set(targets) - effective_tv_set)
        if outside_effective:
            raise TargetConfigError(
                "active resolved targets for %s are not in the rendered TV list: %s"
                % (vendor, ", ".join(outside_effective))
            )

        expected = set(target_config.vendor_targets[vendor])
        if set(targets) != expected:
            raise TargetConfigError(
                "resolved targets for %s do not match %s in %s; rebuild the policy"
                % (vendor, instances[vendor]["targets_key"], target_config.path)
            )

        for target in targets:
            if target in owners:
                raise TargetConfigError(
                    "active resolved target %s is shared by vendors %s and %s"
                    % (target, owners[target], vendor)
                )
            owners[target] = vendor
        scopes[vendor] = targets
    return scopes


def _load_instances(path):
    try:
        with open(path, encoding="utf-8") as fh:
            document = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise TargetConfigError("cannot read privacy registry %s: %s" % (path, exc)) from exc
    instances = document.get("instances")
    if not isinstance(instances, dict) or not instances:
        raise TargetConfigError("privacy registry %s has no instances" % path)
    return instances


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instances", default=DEFAULT_INSTANCES)
    parser.add_argument("--config", default=None)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    meta_parser = subparsers.add_parser("vendor-meta")
    meta_parser.add_argument("vendor")
    resolved_parser = subparsers.add_parser("resolved-targets")
    resolved_parser.add_argument("resolved")
    resolved_parser.add_argument("vendor")
    args = parser.parse_args(argv)

    try:
        instances = _load_instances(args.instances)
        target_config = load_target_config(instances, args.config)
        if args.command == "validate":
            return 0
        if args.vendor not in instances:
            raise TargetConfigError(
                "unknown vendor %s (known: %s)"
                % (args.vendor, ", ".join(instances))
            )
        if args.command == "vendor-meta":
            vendor_config = instances[args.vendor]
            group = vendor_config.get(
                "pihole_group", "TVGuard-Privacy-%s" % args.vendor.upper()
            )
            targets = target_config.vendor_targets[args.vendor]
            print("\t".join([group, vendor_config["targets_key"], ",".join(targets)]))
            return 0

        try:
            with open(args.resolved, encoding="utf-8") as fh:
                resolved = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            raise TargetConfigError(
                "cannot read resolved policy %s: %s" % (args.resolved, exc)
            ) from exc
        scopes = validate_resolved_target_scopes(
            instances, target_config, resolved, [args.vendor]
        )
        print(" ".join(scopes[args.vendor]))
        return 0
    except TargetConfigError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
