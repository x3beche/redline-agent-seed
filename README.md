# redline-agent-seed

Run your **Redline agent** on your own computer.

In Redline you mark up a model or a board and queue a note; an AI agent
does the work. That agent is [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
running on **your** computer and talking to your Redline server with an
agent token. This repository is all you need for it: a start script and
the agent's standing instructions. No Redline source code, no database
password.

On every start the script fetches the **agent kit** from your Redline
server (the command line the agent uses and the instructions it follows,
`GET /api/agent/kit`), so the agent is always in step with the server.
Builds, parts and other heavy work run on the server.

> **Keep the agent running the whole time you develop.** It is what works
> on the notes you queue. If it stops, your notes simply wait in the queue
> until you start it again.

## What you need

- **Claude Code**, installed and signed in (run `claude` once and log in).
- **Python 3.12 or newer** (with `venv`; on Debian/Ubuntu also `python3-venv`).
- **git**.
- Optional: **tmux**, to keep the agent running in the background
  (without it, it runs in the terminal you start it from).
- Optional: **Chrome or Chromium**, for the before/after pictures the
  agent takes of its work.
- **Windows**: WSL (`wsl --install`), with Claude Code, Python and git
  installed inside WSL. The PowerShell line below runs everything there.

## 1. Make a token

In Redline: **user menu > Agent tokens > New token**. Name it after the
computer it will run on (for example `laptop`) and press *Make token*.
The token (`rlat_...`) is shown **once**, together with the full line to
run - copy it from there.

## 2. Run one line

macOS / Linux / WSL:

```bash
git clone https://github.com/x3beche/redline-agent-seed; cd redline-agent-seed && ./start.sh --api https://YOUR-REDLINE-SERVER --token rlat_YOUR_TOKEN
```

Windows (PowerShell):

```powershell
git clone https://github.com/x3beche/redline-agent-seed; cd redline-agent-seed; powershell -ExecutionPolicy Bypass -File start.ps1 -Api https://YOUR-REDLINE-SERVER -Token rlat_YOUR_TOKEN
```

The Agent tokens page shows this line with your server and your token
already filled in. `--name` (`-Name`) sets the name the agent's work is
shown under; it defaults to `main`. Leave `--token` out and the script asks
for it without showing it.

What it does:

1. checks Python, Claude Code and the token;
2. saves the address, token and name in `.env` in this folder;
3. fetches the agent kit into `kit/` and installs its few Python packages
   in `kit/.venv`;
4. starts Claude Code in `kit/` as your main agent - in a tmux session
   called `redline-agent` when tmux is there, and opens it. The first time,
   Claude Code asks whether you trust the folder: say yes. Detach with
   `Ctrl-b d`; the agent keeps running.

Then go back to Redline: the first-run guide and the Agent tokens page
show the agent as **connected**. Queue a note and watch it work.

## 3. Keep it running

```bash
./start.sh                  # start it again - settings from .env, kit updated
./start.sh --restart        # stop it and start it again, updated
./start.sh --stop           # stop it
./start.sh --status         # running? token still good?
./start.sh --foreground     # run in this terminal instead of tmux
tmux attach -t redline-agent    # watch it (Ctrl-b d to leave it running)
```

On Windows use the same options on `start.ps1`: `-Restart`, `-Stop`,
`-Status`, `-Foreground`.

**Updating**: the kit updates itself on every start (`./start.sh --restart`
picks up a new one). For a newer start script: `git pull`.

## Your token

- It lives only in `.env` in this folder: readable only by you (mode 600),
  listed in `.gitignore`, never committed. Do not paste it anywhere else.
- The one-line command contains it, so it is also in your shell history.
  On a shared computer, leave `--token` out and type it when asked.
- Everything the agent does is recorded in Redline under the token's
  name. A token is at most an *editor* and only works in your own space.
- **Revoke it** any time under Agent tokens (*Revoke*): the agent stops at
  once. To use a new one: `./start.sh --restart --token rlat_NEW`.
- Lost computer? Revoke its token; nothing else is stored there.

## Troubleshooting

- *token is unknown, revoked or expired*: make a new one and run
  `./start.sh --restart --token rlat_...`.
- *Python could not make a virtual environment*: `sudo apt install python3-venv`
  (or `python3.12-venv`), or install [uv](https://docs.astral.sh/uv/).
- *CERTIFICATE_VERIFY_FAILED* on macOS: run *Install Certificates.command*
  from your Python's folder in Applications.
- Not connected in Redline: `./start.sh --status`, then
  `tmux attach -t redline-agent` to see what the agent is doing.
- To choose how Claude Code is started, set `REDLINE_CLAUDE_FLAGS` in
  `.env` (default `--allow-dangerously-skip-permissions`, which lets you
  switch it to work without asking; the kit already allows its own
  commands).

## Türkçe

Bu depo, Redline ajanınızı **kendi bilgisayarınızda** çalıştırmak için
gereken her şeyi içerir: bir başlatma betiği ve ajanın talimatları. Redline
kaynak kodu ya da veritabanı şifresi gerekmez; ajan, sunucunuza bir ajan
anahtarıyla bağlanır ve her başlangıçta ajan kitini sunucudan indirir.

1. **Anahtar oluşturun**: Redline'da kullanıcı menüsü > *Ajan anahtarları*
   > *Yeni anahtar*. Anahtar (`rlat_...`) yalnızca bir kez gösterilir;
   çalıştırılacak satır da hemen orada, anahtarınız ve sunucu adresiniz
   doldurulmuş olarak çıkar.
2. **Tek satırı çalıştırın** (macOS / Linux / WSL):
   `git clone https://github.com/x3beche/redline-agent-seed; cd redline-agent-seed && ./start.sh --api https://SUNUCUNUZ --token rlat_ANAHTARINIZ`
   Windows'ta PowerShell satırını kullanın (ajan WSL içinde çalışır).
3. **Açık tutun**: Ajan, kuyruğa aldığınız notlar üzerindeki işi yapan
   şeydir; geliştirdiğiniz sürece bilgisayarınızda çalışır durumda olmalı.
   Durursa notlar kuyrukta bekler. `./start.sh` yeniden başlatır (ve
   günceller), `./start.sh --stop` durdurur, `tmux attach -t redline-agent`
   izlemenizi sağlar.

Gerekenler: oturum açılmış Claude Code, Python 3.12+, git (isteğe bağlı
tmux ve Chrome). Anahtar yalnızca bu klasördeki `.env` dosyasında durur
(yalnızca siz okuyabilirsiniz, git'e girmez); başka bir yere yapıştırmayın.
Geri almak için *Ajan anahtarları* sayfasında *Revoke*'a basın.
