# tang-arm-docker

Static, from-scratch arm64 build of [tang](https://github.com/latchset/tang), the NBDE key server, for the RouterOS container feature.

Image: `ghcr.io/zumoshi/tang-arm-docker:arm64`

## RouterOS quick start

Written for boards without an external disk, hAP ax class, check with `/disk print`. With no disk attached, plain relative paths resolve against internal flash.

```
# one-time, needs physical reset-button confirmation
/system/device-mode/update container=yes

# key storage, populated on first start
/container/mounts/add list=tang-db src=containers/tang-db dst=/db

/container/add remote-image=ghcr.io/zumoshi/tang-arm-docker:arm64 \
    interface=veth1 root-dir=containers/tang mountlists=tang-db \
    logging=yes start-on-boot=yes
/container/start [find remote-image~"tang-arm-docker"]
```

`tangd` listens on 9090 and generates its own signing (ES512) and exchange (ECMR) keys on first start when the key directory is empty. No keygen step. Check it:

```
curl http://<router-ip>:9090/adv
```

Keys live in `containers/tang-db` on the router. Clearing that directory makes `tangd` generate a fresh pair on the next start, and previously advertised keys stop being served.

## Changing the port

The entrypoint is baked as `/tangd -l -p 9090 /db`. Override it to change anything, everything else follows [tang's own docs](https://github.com/latchset/tang).

```
/container/add remote-image=ghcr.io/zumoshi/tang-arm-docker:arm64 interface=veth1 \
    root-dir=containers/tang mountlists=tang-db entrypoint="/tangd -l -p 9091 /db"
```

Entrypoint and cmd values are not shell-parsed, space-split needs RouterOS 7.20+.

## Gotchas

- Omitting `root-dir` puts the container store in RAM, gone on reboot.
- `/container/mounts/add` takes `list=`, not `name=`. Older forum posts show `name=`.
- `diskN/path` prefixes only apply with a real external disk present.
- The router needs DNS configured or the container refuses to start.
- Since RouterOS 7.20 `check-certificate` defaults to yes. If pulls fail: `/certificate/settings/set builtin-trust-anchors=trusted`.
- Container output only reaches the log if the topic is enabled: `/system/logging add topics=container`. `logging=yes` routes output to `/log print`, while `/container/log/print` keeps the last 100 lines per container (RouterOS 7.20+) regardless.

## Desktop

```
docker run -d -p 9090:9090 -v tang-db:/db ghcr.io/zumoshi/tang-arm-docker:arm64
curl http://127.0.0.1:9090/adv
```
