# Voltempo SIL devcontainer

Bringing up the Voltempo six-connector DC simulator on a fresh machine. Everything here is
Voltempo-specific - it sits alongside the stock EVerest devcontainer rather than replacing it.

What you get: six independent 375 kW DC connectors on a 960 kW site, each with its own ISO 15118
stack, simulated car and network link, with EVerest starting automatically when the containers do.

## Where this fits

Two repos, both cloned side by side, and you need both:

| | |
|---|---|
| **`EVerest`** (this one) | the simulator, and everything that starts it |
| **`EVerest-MCP`** | the MCP server that drives it, so Claude can plug in a car, start a session, read the meter and set limits |

**This file is the authority on bringing the container up.** EVerest-MCP's own README describes the
same steps in brief and points here; if the two ever disagree, this one is right, because it lives in
the repo the scripts are in. Work in EVerest-MCP mostly needs nothing from this tree beyond a running
stack.

## Prerequisites

| | |
|---|---|
| Docker Desktop | running, WSL2 backend on Windows |
| Shell | **Git Bash** on Windows - the setup scripts are `bash` |
| Disk | ~15 GB, most of it the EVerest build volume |

## 1. Clone

```bash
git clone https://github.com/Voltempo/EVerest-MCP.git
git clone -b feature/voltempo https://github.com/Voltempo/EVerest.git
cd EVerest
git config core.autocrlf false
```

**The branch matters.** Not upstream, not `main` - `feature/voltempo` carries two patches that exist
nowhere else, and without them the rig cannot do what it claims: `set_evcc_id` (runtime vehicle
identity, upstream PR still open) and `YetiSimulator.max_current_A_import`, without which DC sessions
are hard-capped near 22 kW instead of 375 kW.

> **Windows: `core.autocrlf` must be `false`, and it must be set before anything is checked out.**
> With the default `true`, Git rewrites shell scripts to CRLF and container entrypoints die with
> `exec /entrypoint.sh: no such file or directory`. The file is right there - the kernel is looking
> for an interpreter literally named `/bin/sh\r`. If you have already cloned with `autocrlf=true`,
> set it to `false` and re-checkout the tree.

## 2. Start the stack

```bash
./.devcontainer/sil-up.sh
```

That is the whole command. It creates the `everest-build` volume, generates `.env` for your machine,
and runs `docker compose` with the three compose files in the right order. It is idempotent.

**Do not use plain `docker compose up`.** It fails three different ways here, which is exactly why
the script exists - see the comment block at the top of `sil-up.sh` for the detail.

Five containers should come up:

```
devcontainer-devcontainer-1     the build and run environment
devcontainer-mqtt-server-1      mosquitto      1883, 9001
devcontainer-nodered-1          dashboard      1880
devcontainer-mqtt-explorer-1    MQTT viewer    4000
devcontainer-docker-proxy-1
```

## 3. Build EVerest - first time only

The `everest-build` volume starts empty, so on a new machine EVerest has to be compiled once. Until
it is, the container comes up and stays up but reports `no manager binary at /build/dist/bin/manager`
and idles - deliberately, so you keep the shell you need.

Build **into `/build`, never `/workspace/build`**. Keeping it off the Windows bind mount is the
difference between a tolerable build and an unusable one, and the volume survives container
recreation:

```bash
docker exec -it devcontainer-devcontainer-1 bash
cmake -B /build -S /workspace -DCMAKE_INSTALL_PREFIX=/build/dist
make -C /build install -j$(nproc)
```

Around 1,700 objects and ~11 GB. **A full recompile with the dependency caches already warm measured
10 min 49 s on 32 cores**; a genuine first build is longer, because it fetches every CPM dependency
first. `-j$(nproc)` is doing the work, so scale accordingly - on 8 cores expect roughly four times
that. Start it and go and do something else. Then:

```bash
docker restart devcontainer-devcontainer-1
```

Every later start reuses the volume and skips all of this, which is the entire point of it.

## 4. Verify

```bash
docker logs -f devcontainer-devcontainer-1
```

You want, in order:

```
sil-net-setup: 6 connector link(s) ready (6 created, 0 already present)
[sil-start] waiting for MQTT broker at mqtt-server:1883
[sil-start] starting EVerest with /workspace/config/config-sil-6evse-dc.yaml (6 connectors)
```

then six `🌀🌀🌀 Ready to start charging 🌀🌀🌀` lines, one per connector. The manager's own output
also lands in `/tmp/everest-manager.log` inside the container.

The Node-RED dashboard is at <http://localhost:1880/ui> and MQTT Explorer at
<http://localhost:4000>.

## What starts automatically, and how to change it

`docker-compose.buildvol.yml` replaces the stock `sleep infinity` command with `sil-start.sh`, so
EVerest comes up with the container. Stock EVerest does not do this, and its absence fails quietly in
a way worth knowing: dashboard buttons still appear to work, because an MQTT publish never fails when
nothing is subscribed, while every readout goes dead. Buttons silent *and* readouts dead means the
manager is gone; buttons silent with readouts live is a real bug.

Set these in `.devcontainer/.env`:

| Variable | Default | |
|---|---|---|
| `EVEREST_AUTOSTART` | `1` | `0` for a bare shell container |
| `EVEREST_CONFIG` | `config-sil-6evse-dc.yaml` | see below |
| `EVEREST_CONNECTORS` | `6` | veth pairs to create - must match the config |
| `EVEREST_PREFIX` | `/build/dist` | install prefix passed to the manager |

### Which config

| Config | Connectors | Authorisation | Talks to |
|---|---|---|---|
| `config-sil-6evse-dc.yaml` | 6, one charge point | `DummyTokenProvider` + `DummyTokenValidator` - self-authorising | nothing outside the machine |
| `config-sil-6evse-3vsecc.yaml` | 6, as 3 OCPP charge points | `DummyTokenProviderManual` + `OCPP` - the CSMS decides | a live CSMS over OCPP 1.6J |

**The authorisation difference decides whether a session ever charges.** On the standalone config,
plugging in authorises itself and the session runs unattended. On the 3-vSECC config a plugged-in
connector holds at `AuthRequired` until the CSMS starts the charge - correct behaviour, and
indistinguishable from a broken rig if you are not expecting it. Anything driving a session on its
own needs the standalone config.

The standalone config is the default deliberately: the 3-vSECC one registers three live charge points
with a commercial CSMS, which should be something you ask for, not something that happens because you
started Docker. It also needs per-board credentials that are not in this repo.

Both configs are generated - `--connector-kw` and `--station-kw` are spread across six settings in
five modules, each of which caps the result on its own, so regenerate rather than editing the YAML.
The generator lives in the EVerest-MCP repo as `sim/generate_sil_config.py`.

## Connecting to a CSMS

Only needed for `config-sil-6evse-3vsecc.yaml`. Skip this entirely if you are working offline.

**The station is three charge points, not one.** One vSECC board serves two connectors, so a
six-connector charger presents three separate OCPP identities. There is no way to present it as one,
and connector ids restart at 1 on each board - EVerest forces that. Create three charge points in the
CSMS, OCPP 1.6J, security profile 2, and note the authorisation key it issues for each. They are not
interchangeable.

```bash
cp .devcontainer/monta-credentials.example.env .devcontainer/monta-credentials.env
# fill in MONTA_CP_1..3 and MONTA_KEY_1..3
./.devcontainer/monta-setup.sh
```

That writes `/build/monta/vsecc{1,2,3}/ocpp-monta.json` from `ocpp-monta.example.json`, filling in
the three fields that differ per board and leaving the other forty alone. It refuses to overwrite an
existing config unless you pass `--force`, because each board keeps its own OCPP database and a
config whose identity no longer matches its database is a confusing thing to debug.

Then point the stack at the OCPP config and recreate:

```bash
echo 'EVEREST_CONFIG=/workspace/config/config-sil-6evse-3vsecc.yaml' >> .devcontainer/.env
./.devcontainer/sil-up.sh --force-recreate
```

**Nothing with a key in it is in this repo, and it must stay that way.** The configs live on the
`everest-build` volume; `monta-credentials.env` is gitignored. Only the template and the example are
tracked.

Two things that catch people out:

- **`CompositeScheduleDefaultLimitWatts` must be 375 kW, not Monta's 240 kW default.** It is what the
  CSMS assumes when no charging profile is active, so at 240 kW every session is silently capped a
  third below the cable rating. Worse, it hides the charger's behaviour: the 80 kW sharing steps give
  a connector 375, 320 or 240 kW at one to four vehicles, all of which a 240 kW cap flattens to the
  same number - the station only looks like it is sharing power once five vehicles are plugged in.
  The template sets 375 kW. A charging profile is only observable if it asks for less.
- **One OCPP connection per identity.** Start a second manager holding the same charge point and the
  CSMS displaces the first, which shows up as `Client closed, was not requested internally` in the
  log of the one that lost.

## Traps

- **Changing `command:` or any `EVEREST_*` value needs a container recreate, not a restart.** A
  restart reuses the command baked into the container at creation, so your change silently does
  nothing: `./.devcontainer/sil-up.sh --force-recreate`.
- **The veth pairs are wiped on every container recreate.** Without them the ISO 15118 modules bind
  the wrong interfaces, connectors cross-pair silently, and the stack aborts on boot. `sil-start.sh`
  recreates them; a manager you start by hand does not, so run `sil-net-setup.sh` first if you do.
- **`docker restart devcontainer-devcontainer-1` restarts EVerest**, and it is the only fix for a
  simulated car whose ISO 15118 stack has shut down. EVerest has no partial restart anyway - the
  manager treats any module exit as fatal and tears down every module.
- **Never `docker compose down -v`.** It would take the ~11 GB build with it. `everest-build` is
  declared `external` specifically to make that harder.
- **Changing `UID`/`GID` in `.env` after building makes the build volume unwritable.** The Dockerfile
  runs `usermod --uid ${USER_UID}`, but the files already in `everest-build` and in the CPM cache keep
  the old owner. EVerest still *runs* - both are world-readable - so this stays hidden until the next
  build, which fails with `Permission denied: /build/dependencies.cmake` or
  `.../cmake.lock creation failed (check permissions)`. Fix by taking ownership:
  ```bash
  docker exec -u root devcontainer-devcontainer-1 \
    chown -R "$(id -u):$(id -g)" /build /home/docker
  ```
- **`The "SSH_AUTH_SOCK" variable is not set` on every start is expected on Windows** and can be
  ignored. The stock compose file bind-mounts your SSH agent socket; with no agent the path resolves
  to the `.devcontainer` directory, which is harmless because nothing in the SIL flow uses SSH.

## Why each connector needs its own network link

V2G discovery in SIL is real link-local IPv6 multicast on a fixed UDP port. Connectors sharing an
interface pair with each other's cars silently and non-deterministically. `sil-net-setup.sh` creates
one veth pair per connector - `evN-evse` / `evN-car` - and `sil-start.sh` runs it before the manager.

## Files

| | |
|---|---|
| `sil-up.sh` | host-side bring-up - the only command you need |
| `sil-start.sh` | the container's command: veth pairs, wait for broker, start manager |
| `sil-net-setup.sh` | creates the per-connector veth pairs |
| `docker-compose.buildvol.yml` | the `/build` volume mount and the autostart |
| `.env.example` | template for the gitignored `.env` |
