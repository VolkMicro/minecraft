#!/usr/bin/env bash
# setup-launchserver.sh
# Run ONCE after first deploy to configure GravitLauncher LaunchServer.
# Usage (from server, in infra/ directory):
#   bash gravitlauncher/setup-launchserver.sh
#
# What it does:
#   1. Waits for LaunchServer to be ready
#   2. Loads MirrorHelper module (downloads Java, NeoForge installer from mirrors)
#   3. Loads GenerateCertificate module (for signed launcher)
#   4. Applies workspace defaults
#   5. Generates certificate
#   6. Downloads NeoForge 1.21.1 installer
#   7. Installs client "CreateAeronautics" with NeoForge 1.21.1
#   8. Downloads JavaRuntime + runtime UI
#   9. Downloads mods from Modrinth
#  10. Syncs profiles index
#  11. Builds Launcher.exe (and Launcher.jar)

set -euo pipefail

GL="docker compose exec -T gravitlauncher"
CMD() { echo "$1" | $GL socat UNIX-CONNECT:/app/data/control-file - ; sleep 2; }

echo "==> Waiting for LaunchServer to start..."
for i in $(seq 1 30); do
    if docker compose exec -T gravitlauncher test -S /app/data/control-file 2>/dev/null; then
        echo "    OK (attempt $i)"
        break
    fi
    echo "    Waiting... ($i/30)"
    sleep 3
done

echo ""
echo "==> Step 1: Load MirrorHelper"
CMD "modules load MirrorHelper"

echo "==> Step 2: Apply workspace"
CMD "applyworkspace"

echo "==> Step 3: Generate certificate"
CMD "modules load GenerateCertificate"
CMD "generatecertificate"

echo "==> Step 4: Download NeoForge installer for 1.21.1"
CMD "downloadinstaller NEOFORGE 1.21.1"

echo "==> Step 5: Install client CreateAeronautics"
CMD "installclient CreateAeronautics 1.21.1 NEOFORGE"

echo "==> Step 6: Download JavaRuntime"
docker compose exec gravitlauncher wget -q -O /app/data/JavaRuntime.jar \
    https://github.com/GravitLauncher/LauncherRuntime/releases/latest/download/JavaRuntime.jar

echo "==> Step 7: Download runtime UI"
docker compose exec gravitlauncher bash -c "
    mkdir -p /app/data/runtime && \
    cd /app/data/runtime && \
    wget -q https://github.com/GravitLauncher/LauncherRuntime/releases/latest/download/runtime.zip && \
    unzip -o runtime.zip && rm runtime.zip
"

echo "==> Step 8: Download Prestarter.exe"
docker compose exec gravitlauncher wget -q -O /app/data/Prestarter.exe \
    https://github.com/GravitLauncher/LauncherPrestarter/releases/latest/download/Prestarter.exe

echo "==> Step 9: Persist Prestarter module in modules.json (including JavaRuntime.jar), then restart"
docker compose exec gravitlauncher bash -c \
    'echo "{\"loadModules\":[\"MirrorHelper_module\",\"Prestarter_module\"],\"loadLauncherModules\":[\"JavaRuntime.jar\"]}" > /app/data/modules.json'
docker compose restart gravitlauncher
echo "    Waiting for restart..."
sleep 10
for i in $(seq 1 20); do
    if docker compose exec -T gravitlauncher test -S /app/data/control-file 2>/dev/null; then
        echo "    OK (attempt $i)"
        break
    fi
    sleep 3
done

echo "==> Step 10: Download 19 mods into client folder"
MODS_DIR="/app/data/updates/CreateAeronautics/mods"
docker compose exec gravitlauncher mkdir -p "$MODS_DIR"

download_mod() {
    local filename="$1"
    local url="$2"
    echo "    Downloading $filename..."
    docker compose exec gravitlauncher wget -q -O "$MODS_DIR/$filename" "$url"
}

download_mod "create-1.21.1-6.0.10.jar" "https://cdn.modrinth.com/data/LNytGWDc/versions/UjX6dr61/create-1.21.1-6.0.10.jar"
download_mod "create-aeronautics-bundled-1.21.1-1.1.3.jar" "https://cdn.modrinth.com/data/oWaK0Q19/versions/1sv6OtSz/create-aeronautics-bundled-1.21.1-1.1.3.jar"
download_mod "createdeco-2.1.3.jar" "https://cdn.modrinth.com/data/sMvUb4Rb/versions/qrcMVoBD/createdeco-2.1.3.jar"
download_mod "sable-neoforge-1.21.1-1.1.3.jar" "https://cdn.modrinth.com/data/T9PomCSv/versions/g8CObHcP/sable-neoforge-1.21.1-1.1.3.jar"
download_mod "FarmersDelight-1.21.1-1.3.0.jar" "https://cdn.modrinth.com/data/R2OftAxM/versions/XJKk7DgU/FarmersDelight-1.21.1-1.3.0.jar"
download_mod "sophisticatedbackpacks-1.21.1-3.25.41.1683.jar" "https://cdn.modrinth.com/data/TyCTlI4b/versions/TiDxy94j/sophisticatedbackpacks-1.21.1-3.25.41.1683.jar"
download_mod "sophisticatedcore-1.21.1-1.4.29.1752.jar" "https://cdn.modrinth.com/data/nmoqTijg/versions/M4Xj4ig7/sophisticatedcore-1.21.1-1.4.29.1752.jar"
download_mod "waystones-neoforge-1.21.1-21.1.30.jar" "https://cdn.modrinth.com/data/LOpKHB2A/versions/ylfzux81/waystones-neoforge-1.21.1-21.1.30.jar"
download_mod "balm-neoforge-1.21.1-21.0.57.jar" "https://cdn.modrinth.com/data/MBAkmtvl/versions/XC1JUHmA/balm-neoforge-1.21.1-21.0.57.jar"
download_mod "lootr-neoforge-1.21.1-1.11.37.118.jar" "https://cdn.modrinth.com/data/EltpO5cN/versions/EB2B27qh/lootr-neoforge-1.21.1-1.11.37.118.jar"
download_mod "YungsApi-1.21.1-NeoForge-5.1.6.jar" "https://cdn.modrinth.com/data/Ua7DFN59/versions/ZB22DE9q/YungsApi-1.21.1-NeoForge-5.1.6.jar"
download_mod "YungsBetterDungeons-1.21.1-NeoForge-5.1.4.jar" "https://cdn.modrinth.com/data/o1C1Dkj5/versions/D6aZn0Em/YungsBetterDungeons-1.21.1-NeoForge-5.1.4.jar"
download_mod "YungsBetterMineshafts-1.21.1-NeoForge-5.1.1.jar" "https://cdn.modrinth.com/data/HjmxVlSr/versions/Go3nbneL/YungsBetterMineshafts-1.21.1-NeoForge-5.1.1.jar"
download_mod "YungsBetterStrongholds-1.21.1-NeoForge-5.1.3.jar" "https://cdn.modrinth.com/data/kidLKymU/versions/8U0dIfSM/YungsBetterStrongholds-1.21.1-NeoForge-5.1.3.jar"
download_mod "YungsBetterDesertTemples-1.21.1-NeoForge-4.1.5.jar" "https://cdn.modrinth.com/data/XNlO7sBv/versions/GQ9iNWkI/YungsBetterDesertTemples-1.21.1-NeoForge-4.1.5.jar"
download_mod "ferritecore-7.0.3-neoforge.jar" "https://cdn.modrinth.com/data/uXXizFIs/versions/x7kQWVju/ferritecore-7.0.3-neoforge.jar"
download_mod "modernfix-neoforge-5.27.3+mc1.21.1.jar" "https://cdn.modrinth.com/data/nmDcB62a/versions/QbebWhuK/modernfix-neoforge-5.27.3%2Bmc1.21.1.jar"
download_mod "jei-1.21.1-neoforge-19.27.0.340.jar" "https://cdn.modrinth.com/data/u6dRKJwZ/versions/YAcQ6elZ/jei-1.21.1-neoforge-19.27.0.340.jar"
download_mod "Jade-1.21.1-NeoForge-15.10.5.jar" "https://cdn.modrinth.com/data/nvQzSEkH/versions/xnwH0L0Z/Jade-1.21.1-NeoForge-15.10.5.jar"

echo ""
echo "==> Step 11: Configure memory auth (no database required) + server address"
# Patch LaunchServer.json to set memory auth and project name
docker compose exec gravitlauncher bash -c "
python3 -c \"
import json, sys
with open('/app/data/LaunchServer.json', 'r') as f:
    cfg = json.load(f)
cfg['projectName'] = 'CreateAeronautics'
cfg['auth'] = {
    'std': {
        'core': {'type': 'memory'},
        'textureProvider': {'type': 'void'},
        'isDefault': True,
        'displayName': 'Offline'
    }
}
with open('/app/data/LaunchServer.json', 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print('LaunchServer.json updated')
\"
"

echo "==> Step 12: Patch profile — set server address + RAM"
docker compose exec gravitlauncher bash -c "
python3 -c \"
import json, os, glob
profiles = glob.glob('/app/data/profiles/*.json')
for p in profiles:
    with open(p, 'r') as f:
        cfg = json.load(f)
    cfg['servers'] = [{'name': 'Create Aeronautics', 'serverAddress': '95.105.73.172', 'serverPort': 25565, 'isDefault': True}]
    cfg['settings'] = {'ram': 4096, 'autoEnter': False, 'fullScreen': False}
    cfg['info'] = 'Create Aeronautics | Industrial Skyworks'
    with open(p, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f'Patched {p}')
\"
"

echo "==> Step 13: Build Launcher.exe (Prestarter wraps JAR into EXE)"
CMD "build"

echo ""
echo "================================================================"
echo "  GravitLauncher setup complete!"
echo "  Launcher.exe available at:"
echo "    http://idiot-home.ru:7240/Launcher.exe"
echo "  LaunchServer API:"
echo "    ws://idiot-home.ru:7240/api"
echo "================================================================"
