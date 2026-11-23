# BTX T-Rex Miner

A single-file Bash control panel for mining **BitCore (BTX)** on the `megabtx`
algorithm with [T-Rex](https://github.com/trexminer/T-Rex) 0.19.14 on NVIDIA GPUs.
Defaults to [zpool.ca](https://zpool.ca/algo/megabtx).

It installs and verifies T-Rex, keeps it running, auto-tunes unstable GPUs, and
gives you a status dashboard. Use the keyboard menu, or run it headless over SSH or cron.

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/codyvolckmar/btx-trex-miner/main/trex-btx.sh
chmod +x trex-btx.sh
sudo BTX_WALLET=YOUR_ADDRESS BTX_WORKER=rig1 ./trex-btx.sh --install
sudo ./trex-btx.sh --start
sudo ./trex-btx.sh --status
```

Or run `sudo ./trex-btx.sh` for the interactive menu.

## Self-healing GPUs

T-Rex runs with `--exit-on-cuda-error`, and a supervisor watches it:

1. **A GPU crashes** (e.g. `illegal memory access ... GPU #0`): the supervisor reads
   which GPU failed from the log, lowers **that GPU's** intensity by `STEP` (default 2),
   and restarts T-Rex within seconds. The other GPUs keep their speed.
2. **A GPU stops hashing** (0 H/s for `DEAD_AFTER` seconds, default 120): same treatment.
3. At `MIN_INTENSITY` (default 14) it enables T-Rex low-load mode for that GPU.
4. If it still fails, the GPU is disabled (`DISABLE_UNSTABLE=yes`) so the rest keep mining.

Tuning is saved per GPU in `gpu-tune`, so a weak card stays tuned across restarts.
Reset with **Settings → Reset GPU tuning** or `--reset-tuning`.
If the miner crash-loops (3 fast exits in a row), restarts back off to 15 s.

## Commands

| Command | What it does |
|---|---|
| `./trex-btx.sh` | Interactive menu |
| `--status [lines]` | Status, per-GPU hashrate/temp/intensity/crashes, log tail |
| `--preflight` | Check driver, binary, wallet, GPUs |
| `--start` / `--stop` / `--restart` | Headless control |
| `--install` | Download T-Rex, verify SHA-256, install |
| `--reset-tuning` | Forget per-GPU intensity drops and disabled GPUs |

| Env var | Default | Meaning |
|---|---|---|
| `BTX_TREX_DIR` | `/opt/btx-trex` | Where everything lives |
| `BTX_WALLET` | (none) | Wallet used when `miner.conf` is first created |
| `BTX_WORKER` | hostname | Worker name used when `miner.conf` is first created |

## Config

`miner.conf` (plain shell variables, edited via the menu or by hand):
`POOL`, `WALLET`, `PASS` (default `c=BTC,zap=BTX`), `WORKER`, `DEVICES`, `EXTRA`,
`STEP`, `MIN_INTENSITY`, `DISABLE_UNSTABLE`, `DEAD_AFTER`, `GRACE`, `CHECK_EVERY`, `RESTART_DELAY`.

## Requirements

- x86_64 Linux, NVIDIA GPU, driver 455+ (`nvidia-smi`, `libnvidia-ml.so.1`)
- `bash`, `curl`, `jq`, `whiptail` (installed via `apt` if missing)

## Notes

- Containers usually can't set power limits; the script tunes intensity only.
- Not started on boot: add `@reboot /path/to/trex-btx.sh --start` to root's crontab.
- T-Rex charges a 1% dev fee. It is a closed-source third-party binary; run at your own risk.

## License

MIT
