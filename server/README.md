# Server Guide

Dockerized Minecraft server for Create Aeronautics on Minecraft `1.21.1` with NeoForge `21.1.227`.

## Included

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
- Spark
- Chunky

## Local Start

```powershell
docker compose up -d
docker compose logs -f mc
```

Server is ready when logs contain `Done (...)!`.

## Verify Locally

```powershell
.\verify-server.ps1
```

## Remote Deploy

Default deploy target:

- user: `microvolk`
- host: `10.14.0.113`
- dir: `~/infra`
- key: `%USERPROFILE%\.ssh\id_ed25519`

Run:

```powershell
.\deploy-remote.ps1
```

## Important Settings

- `ONLINE_MODE=false` so TLauncher and offline accounts can join
- `ENFORCE_WHITELIST=false` so any player can connect
- `NEOFORGE_VERSION=21.1.227` is pinned because autodetection was unstable on remote startup