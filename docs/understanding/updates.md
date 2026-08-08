# Updates & channels

Vibranium updates itself through its Git repository.
Unlike a traditional package update, a Vibranium update replaces the runtime files in place 
and then applies any required migrations for structural changes.

## Update channels

Vibranium provides two update channels:

| Channel | Description |
|---------|-------------|
| **release** | Stable releases. The default channel installed for normal users. |
| **upstream** | The latest `master` branch state. Intended for testing newer changes. |

The channel is selected during installation and can be changed later in **Vibranium Menu** -> **Settings** -> **General**, or with:

```bash
vb-dev-switch-channel
```

Switching channels performs a repository checkout operation.  
If the installation contains uncommitted changes, the operation is refused until they are handled.

After switching:

- the Vibranium runtime is reloaded
- the update service is restarted

## Updating Vibranium

The update action **Vibranium Menu -> Update -> Update Vibranium** runs the `vb-update` command.  
The update process:

1. Temporarily stores local modifications in the installation directory.
2. Pulls the latest repository state.
3. Restores local modifications.
4. Runs required migrations.
5. Reloads the runtime.

If restoring local changes causes conflicts, the update stops and provides instructions for resolving them.

## Background update checks

Vibranium periodically checks for available updates using the `vibranium-update.timer` system unit.  
The check runs without user interaction and stores the result in: `$VIBRANIUM_STATE/update.available`  
The Waybar update module reads this state and displays when a new Vibranium version is available.

Current installation information can be viewed with:

```bash
vb-version
```

It shows:

- current version
- active channel
- update availability
- repository state

## Migrations

Updates may require changes beyond replacing files.

For example:

- moving configuration files
- enabling new services
- converting old settings
- creating new runtime state

These changes are handled through migrations stored in `$VIBRANIUM/migrations/`.  
Each migration is a timestamped shell script.

During an update:

- only migrations newer than the last applied one are executed
- migrations run in timestamp order
- each migration runs only once

Applied migrations are tracked in `$VIBRANIUM_STATE/migrations/`.  
If a migration fails, the update reports the failing step instead of silently continuing.

## Local modifications

The Vibranium installation can contain local changes in `~/.local/share/vibranium/`.  
The updater automatically stashes local modifications before updating and restores them afterward.

Considerations:

- If upstream changed the same files, stash restoration may require manual conflict resolution
- Local changes are kept safe until resolved
- `vb-update --nuke` can be used to discard local modifications and restore the repository state completely

## System updates

Vibranium self-updates and system package updates are separate operations.

Updating Vibranium (**Vibranium Menu** -> **Update** -> **Update Vibranium**) only updates Vibranium itself.  
Updating Arch packages (**Vibranium Menu** -> **Update** -> **Update system**) runs the normal system upgrade process through pacman/AUR tooling.

## Versioning

Vibranium versions follow Git tags:

```text
v0.7.x
```

`vb-version` shows the exact installed state, including the current commit.
