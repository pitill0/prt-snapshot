# prt-snapshot

Snapshot manager for the installed package set handled by `prt-get` on CRUX.

## Description

`prt-snapshot` stores the list returned by `prt-get listinst` and can later
inspect a stored snapshot, compare it with the current package set, or restore
package membership to that snapshot.

A typical use case is to capture a known minimal CRUX installation, install a
port and its dependencies for testing, and then return the installed package set
to the captured baseline.

## Requirements

### Software

- bash
- prt-get
- standard CRUX userland tools used by the script (`diff`, `find`, `grep`,
  `mktemp`, `stat`, and related core utilities)

### Snapshot directory

Create the snapshot store before using operational commands:

```sh
sudo mkdir -p /var/lib/pkg/snapshots
sudo chown root:root /var/lib/pkg/snapshots
sudo chmod 755 /var/lib/pkg/snapshots
```

The directory must:

- be owned by root;
- not be a symbolic link;
- not be writable by group or others.

Operational commands require root. `help` and `version` do not require an
initialized snapshot store.

## Usage

```text
prt-snapshot <command> [options]

Commands:
  clean                         Remove all stored snapshots
  store msg                     Take a snapshot of installed ports
  restore num [--dry-run|--yes] Restore package membership to snapshot num
  diff num                      Show differences between current state and snapshot num
  show num [--packages]         Show snapshot details or package names only
  list                          List stored snapshots
  help                          Show usage information
  version                       Show version information
```

Examples:

```sh
sudo prt-snapshot store "clean base"
sudo prt-snapshot list
sudo prt-snapshot show 1
sudo prt-snapshot show 1 --packages
sudo prt-snapshot diff 1
sudo prt-snapshot restore 1 --dry-run
sudo prt-snapshot restore 1
```

For non-interactive restore:

```sh
sudo prt-snapshot restore 1 --yes
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

## Inspecting snapshots

`show <num>` displays:

- snapshot ID;
- creation timestamp;
- stored message;
- package count;
- package names.

For scripting, `show <num> --packages` emits only validated package names, one
per line.

Snapshot data is validated before output is produced.

## Restore behavior

During restore, packages present in the current system but absent from the
snapshot are removed. Packages present in the snapshot but absent from the
current system are installed with `prt-get install`.

Before the first package operation, `prt-snapshot`:

1. calculates the complete restore plan;
2. validates every package name and operation;
3. resolves an installation order for missing packages with `prt-get quickdep`;
4. filters that dependency information strictly to packages already present in
   the target snapshot.

`prt-get depinst` is intentionally not used. Dependency discovery is used only
for ordering: it never expands snapshot membership.

If the current ports tree reports a dependency that was not part of the target
snapshot, that package is not added to the restore.

### Preview and confirmation

`restore <num> --dry-run` prints the exact removal and dependency-aware
installation plan without changing package state or pruning snapshot history.

Interactive `restore <num>` prints the same plan and asks for confirmation
before applying it.

Non-interactive restore requires explicit opt-in with `--yes` or `--dry-run`.

A cancelled restore does not modify package state or snapshot history.

## Failure behavior

Restore ordering is resolved before any destructive package operation begins.

If plan validation or `prt-get quickdep` fails, restore aborts before package
state is changed.

If a package removal or installation later fails, restore aborts immediately and
does not prune snapshots newer than the requested target.

Newer snapshot history is removed only after a completely successful applied
restore.

## Safety guarantees

The safety baseline introduced in 0.4 remains in place:

- existing snapshots are never overwritten by index reuse;
- snapshot IDs and package names are validated;
- snapshots are published only after successful capture;
- temporary files are kept outside the numbered snapshot namespace;
- interrupted or failed operations clean temporary state when possible;
- a failed restore does not delete newer snapshots;
- `clean` only removes numeric snapshot files managed by `prt-snapshot`;
- concurrent operations are serialized with a root-owned lock;
- the snapshot directory owner and permissions are validated before use;
- snapshots are created with restrictive permissions.

Version 0.5 adds:

- complete restore-plan validation before mutation;
- `--dry-run` restore preview;
- explicit interactive confirmation and `--yes` for automation;
- dependency-aware installation order with `prt-get quickdep`;
- strict filtering so dependency resolution cannot expand snapshot membership;
- `show` and `show --packages`;
- correct non-zero exit status for invalid CLI usage;
- `help` and `version` independent of snapshot-store initialization.

## Tests

The regression suite currently contains 19 tests and can be run with:

```sh
sudo ./tests/run.sh
```

CI also runs Bash syntax checks, ShellCheck, and the regression suite.

## Bugs and reports

Please contact:

- Victor Martinez: `pitillo at crux-arm dot nu`
- Jose V Beneyto: `sepen at crux dot nu`
