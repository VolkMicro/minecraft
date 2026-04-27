# Client Guide

This folder contains a modern one-click Windows launcher for your Create Aeronautics tech server.

## One-Click UX

The launcher is now GUI-first:

- dark modern window (no spammy popup OK dialogs)
- server description and status at the top
- live progress bar and scrolling operation log
- auto-start flow on open: prepare client, sync mods, launch game
- manual buttons: `Prepare and Play` and `Update Only`

## What It Does Automatically

- downloads latest `manifest.json` from server
- installs Java (Temurin 21) if missing via winget
- installs NeoForge client `21.1.227` if missing
- syncs mods to exact server manifest (remove stale + download new)
- tries to install/find launcher, then starts it

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

## Manual Setup (Fallback)

### 1. Install TLauncher

Download TLauncher from the official site and install it.

### 2. Install NeoForge 1.21.1

Download NeoForge installer for `21.1.227` and run `Install client`.

Expected version:

- Minecraft: `1.21.1`
- Loader: `NeoForge`
- NeoForge version: `21.1.227`

### 3. Start the NeoForge profile once

Launch the game once and then close it. This creates the `%APPDATA%\.minecraft\mods` folder.

### 4. Download the mods

Open PowerShell in this folder and run:

```powershell
.\download-client-mods.ps1
```

The script downloads the latest compatible versions from Modrinth into `%APPDATA%\.minecraft\mods`.

### 5. Start the game

In TLauncher select the NeoForge `1.21.1` profile and launch the game.

### 6. Connect to the server

Add this server in Multiplayer:

```text
10.14.0.113:25565
```

## What Gets Installed

Shared mods:

- Create
- Create Aeronautics
- Create Deco
- Sable
- Farmer's Delight
- Sophisticated Backpacks
- Waystones
- Lootr
- YUNG's structures
- FerriteCore
- ModernFix

Client-only quality of life mods:

- JEI
- Jade

## Troubleshooting

### Mod conflict after old pack leftovers

Run the downloader again. It automatically removes old `embeddium*.jar` files before downloading.

### Launcher not found

Auto-client will try in this order:

1. TLauncher executable (common install paths)
2. Minecraft Launcher executable (common install paths)

If none found, it opens TLauncher download page.

### Wrong loader selected

If the game crashes immediately, make sure TLauncher is using `NeoForge 1.21.1`, not Forge, Fabric, or vanilla.

### Empty mods folder

Start NeoForge once before running the downloader.

### Server says incompatible client

Delete old jars from `%APPDATA%\.minecraft\mods`, run the script again, and launch only the NeoForge `1.21.1` profile.