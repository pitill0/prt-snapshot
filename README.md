# prt-snapshot

Snapshot manager for the installed package set handled by `prt-get` on CRUX.

## Description

`prt-snapshot` stores the list returned by `prt-get listinst` and can later
compare the current package set with a stored snapshot or restore membership to
that snapshot.

A typical use case is to capture a known minimal CRUX installation, install a
port and its dependencies for testing, and then remove the packages that were
not present in the original package set.

## Requirements

### Software

- bash
- prt-get
- standard CRUX userland tools used by the script (`diff`, `find`, `grep`,
  `mktemp`, `stat`, and related core utilities)

### Snapshot directory

Create the snapshot store before using the tool:

```sh
sudo mkdir -p /var/lib/pkg/snapshots
sudo chown root:root /var/lib/pkg/snapshots
sudo chmod 755 /var/lib/pkg/snapshots
```

The directory must:

- be owned by root;
- not be a symbolic link;
- not be writable by group or others.

All operational commands currently require root.

## Usage

```text
prt-snapshot <command> [options]

Commands:
  clean         Remove all stored snapshots
  store msg     Take a snapshot of installed ports
  restore num   Restore package membership to snapshot num
  diff num      Show differences between the current package set and snapshot num
  list          List stored snapshots
  help          Show usage information
  version       Show version information
```

Examples:

```sh
sudo prt-snapshot store "clean base"
sudo prt-snapshot list
sudo prt-snapshot diff 1
sudo prt-snapshot restore 1
```

## Snapshot semantics

A snapshot represents the **set of installed package names** reported by
`prt-get listinst`.

It is not a full system snapshot. In particular, it does not capture:

- package versions;
- files outside package ownership;
- configuration changes;
- users or groups created by package hooks;
- caches, databases, or other runtime state;
- the historical state of the ports tree.

Restoring a snapshot therefore means restoring package membership as closely as
possible with the currently available ports tree.

## Restore behavior

During restore, packages present in the current system but absent from the
snapshot are removed. Packages present in the snapshot but absent from the
current system are installed with `prt-get install`.

`prt-get depinst` is intentionally not used. Re-resolving dependencies against a
newer ports tree could introduce packages that were never part of the stored
snapshot.

This also means a restore can fail if missing packages must be reinstalled in a
different dependency order. A failed restore aborts immediately and does not
prune snapshots newer than the requested target.

## Safety guarantees

Version 0.4 introduces the following safety properties:

- existing snapshots are never overwritten by index reuse;
- snapshot IDs and package names are validated before destructive operations;
- snapshots are published only after successful capture;
- temporary files are kept outside the numbered snapshot namespace;
- interrupted or failed operations clean temporary state when possible;
- a failed restore does not delete newer snapshots;
- `clean` only removes numeric snapshot files managed by `prt-snapshot`;
- concurrent operations are serialized with a root-owned lock;
- the snapshot directory owner and permissions are validated before use.

Snapshots are created with restrictive permissions.

## Tests

The regression suite can be run with:

```sh
sudo ./tests/run.sh
```

CI also runs Bash syntax checks, ShellCheck, and the safety regression suite.

## Bugs and reports

Please contact:

- Victor Martinez: `pitillo at crux-arm dot nu`
- Jose V Beneyto: `sepen at crux dot nu`
