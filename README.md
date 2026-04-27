# Minecraft Create Aeronautics Pack

Repository layout for the Create Aeronautics server pack.

## Structure

- `server` - Dockerized NeoForge server, mod list, remote deploy, verification scripts
- `client` - Portable HMCL launcher, pack bootstrap scripts, and client setup guide

## Quick Start

### Server

```powershell
cd .\server
docker compose up -d
docker compose logs -f mc
```

Wait for `Done (...)!` in logs.

### Client

Read [client/README.md](./client/README.md) and then run:

```powershell
cd .\client
.\MinecraftAutoClient.ps1
```

## Remote Deploy

The ready target is:

- host: `10.14.0.113`
- user: `microvolk`
- remote dir: `~/infra`

Run:

```powershell
cd .\server
.\deploy-remote.ps1
```

## Notes

- Server is configured for pirate/offline clients: `ONLINE_MODE=false`
- Whitelist is disabled: `ENFORCE_WHITELIST=false`
- Target stack: Minecraft `1.21.1`, NeoForge `21.1.227`