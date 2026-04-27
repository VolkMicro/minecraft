# Client Guide

This folder contains the Windows client launcher for the Create Aeronautics pack. The current build uses portable HMCL instead of TLauncher.

## Current Flow

The launcher now prepares its own isolated client root under `%LOCALAPPDATA%\MinecraftTechLauncher`.

It does the following automatically:

- downloads the latest `manifest.json`
- installs Java 21 if missing via `winget`
- installs NeoForge `21.1.227` into the portable game directory
- syncs mods to match the server manifest exactly
- downloads portable HMCL if missing or outdated
- writes HMCL config, portable profile, portable account, and RAM settings
- opens HMCL with the pack profile already selected

This avoids conflicts with the normal `%APPDATA%\.minecraft` folder and stops the launcher from falling back to vanilla or another launcher.

Default manifest endpoint:

```text
http://95.105.73.172:8088/manifest.json
```

## Run Script Directly

```powershell
.\MinecraftAutoClient.ps1
```

## Build EXE

```powershell
.\build-client-exe.ps1
```

Output:

```text
client\dist\MinecraftTechLauncher.exe
```

## User Flow

1. Start the launcher.
2. Enter your offline nickname.
3. Choose RAM.
4. Click `Prepare and Open HMCL`.
5. HMCL opens with the pack profile ready to launch.

## Installed Paths

Portable client root:

```text
%LOCALAPPDATA%\MinecraftTechLauncher
```

Important subfolders:

- `game` - NeoForge instance, mods, versions, saves
- `hmcl` - portable HMCL executable
- `.hmcl` - local HMCL config
- `.hmcl-home` - HMCL user data and global config

## Manual Fallback

If you need to bootstrap without the GUI launcher:

1. Download HMCL portable.
2. Install NeoForge `21.1.227` into a dedicated game directory.
3. Sync the mod list from `manifest.json`.
4. Point HMCL profile to that directory and select the `neoforge-21.1.227` version.

## Troubleshooting

### HMCL opens but the game does not start immediately

The launcher prepares HMCL and selects the profile, but HMCL itself remains the final game launcher. Click Launch inside HMCL.

### Wrong nickname

Change the nickname field in the launcher and run `Prepare and Open HMCL` again. The offline account in HMCL will be rewritten.

### Pack mismatch or old mods

Run `Update Pack Only`. The launcher removes stale jars from the portable `mods` directory and downloads the exact set from the manifest.

### Existing normal Minecraft is broken or polluted

This build does not use `%APPDATA%\.minecraft` for the pack anymore. Delete `%LOCALAPPDATA%\MinecraftTechLauncher` and run the launcher again to recreate the portable environment cleanly.