# Client Guide

This folder contains everything needed to prepare a TLauncher client for the Create Aeronautics pack.

## What You Need

1. TLauncher installed
2. Java handled by Minecraft launcher/TLauncher
3. NeoForge `1.21.1`
4. This folder with `client-mods.txt` and `download-client-mods.ps1`

## Full Setup

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

### Wrong loader selected

If the game crashes immediately, make sure TLauncher is using `NeoForge 1.21.1`, not Forge, Fabric, or vanilla.

### Empty mods folder

Start NeoForge once before running the downloader.

### Server says incompatible client

Delete old jars from `%APPDATA%\.minecraft\mods`, run the script again, and launch only the NeoForge `1.21.1` profile.