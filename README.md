# redline-agent-seed

Run your **Workbench agent** on your own computer.

In Workbench you mark up a model or a board and queue a note; an AI agent
does the work. That agent runs on **your** computer and talks to your
Workbench server with an agent token. It runs on
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) by default, or
on [OpenCode](https://opencode.ai/docs/). This repository is all you need for
it: a start script and the agent's standing instructions. No Workbench
source code, no database password.

On every start the script fetches the **agent kit** from your Workbench
server (the command line the agent uses and the instructions it follows,
`GET /api/agent/kit`), so the agent is always in step with the server.
Builds, parts and other heavy work run on the server.

> **Keep the agent running the whole time you develop.** It is what works
> on the notes you queue. If it stops, your notes simply wait in the queue
> until you start it again.

## What you need

- **Claude Code**, installed and signed in (run `claude` once and log in):
  the default runner. Or **OpenCode** (see *OpenCode* below).
- **Python 3.12 or newer** (with `venv`; on Debian/Ubuntu also `python3-venv`).
- **git**.
- Optional: **tmux**, to keep the agent running in the background
  (without it, it runs in the terminal you start it from).
- Optional: **Chrome or Chromium**, for the before/after pictures the
  agent takes of its work.
- **Windows**: WSL (`wsl --install`), with Claude Code (or OpenCode),
  Python and git installed inside WSL. The PowerShell line below runs
  everything there.

## 1. Make a token

In Workbench: **user menu > Agent tokens > New token**. Name it after the
computer it will run on (for example `laptop`) and press *Make token*.
The token (`rlat_...`) is shown **once**, together with the full line to
run - copy it from there.

## 2. Run one line

macOS / Linux / WSL:

```bash
curl -fsSL https://YOUR-REDLINE-SERVER/api/public/install.sh | bash -s -- --token rlat_YOUR_TOKEN
```

Windows (PowerShell):

```powershell
wsl bash -c "curl -fsSL https://YOUR-REDLINE-SERVER/api/public/install.sh | bash -s -- --token rlat_YOUR_TOKEN"
```

That script comes from your own server and has its address already in it, so
the token is the only thing you type. It fetches this repository into
`~/redline-agent-seed` (or updates it when you run the line again) and then
hands everything to the `start.sh` below - the settings, the runner, the tmux
session, the service. Add `--runner opencode`, `--model provider/model`,
`--name`, `--session`, `--headless`, `--service` or `--dry-run` and they go
through as they are. Point it at another server with `--api`.

**Or do it by hand**, if you would rather read the script than pipe it into a
shell (the same script is at `https://YOUR-REDLINE-SERVER/api/public/install.sh`):

```bash
git clone https://github.com/x3beche/redline-agent-seed; cd redline-agent-seed && ./start.sh --api https://YOUR-REDLINE-SERVER --token rlat_YOUR_TOKEN
```

```powershell
git clone https://github.com/x3beche/redline-agent-seed; cd redline-agent-seed; powershell -ExecutionPolicy Bypass -File start.ps1 -Api https://YOUR-REDLINE-SERVER -Token rlat_YOUR_TOKEN
```

The Agent tokens page shows the installer line with your server and your token
already filled in. `--name` (`-Name`) sets the name the agent's work is
shown under; it defaults to `main`. `--session` (`-Session`) names the tmux
session it runs in - give it the name you gave the token, so one computer can
run an agent for two accounts (default `redline-agent`); it is kept in
`config.yaml`. Leave `--token` out and you are asked for it, without it being
shown.

What it does:

1. checks Python and the runner (Claude Code, or OpenCode);
2. saves the server address and the other settings in `config.yaml`, and the
   token in `.env` (readable only by you), in this folder;
3. fetches the agent kit into `kit/` and installs its few Python packages
   in `kit/.venv`;
4. starts the agent in `kit/` - in a tmux session called `redline-agent`
   when tmux is there, and opens it. The first time, the runner asks whether
   you trust the folder: say yes. Detach with `Ctrl-b d`; the agent keeps
   running.

Then go back to Workbench: the first-run guide and the Agent tokens page
show the agent as **connected**. Queue a note and watch it work.

## 3. Keep it running

```bash
./start.sh                  # start it again - settings from config.yaml, kit updated
./start.sh restart          # stop it and start it again, updated
./start.sh stop             # stop it (the service too)
./start.sh status           # service, session, kit and token state
./start.sh attach           # watch it (Ctrl-b d to leave it running)
./start.sh logs             # what the script did, newest last
./start.sh --dry-run        # print the settings it would use, start nothing
./start.sh foreground       # run in this terminal instead of tmux
```

On Windows the same commands work on `start.ps1`: `start.ps1 restart`,
`start.ps1 stop`, `start.ps1 status`, `start.ps1 -Attach`, `start.ps1 -Logs`,
`start.ps1 -DryRun`.

**It resumes the last conversation.** When the computer, the service or the
agent is restarted, the next start carries on the last conversation instead
of beginning again - it re-reads `CLAUDE.md`/`AGENTS.md` (they may have
changed) and continues the main-agent loop.

**Updating**: both parts update themselves on every start, so a computer that
has run the install line once keeps up without it. The **agent kit** is fetched
from your Workbench server each time, and this **repository** is pulled forward
(`git pull --ff-only`) before anything starts - a newer `start.sh` included: the
script then runs itself again from the top with your settings, token and tmux
session untouched, because `config.yaml`, `.env`, `logs/` and `kit/` are
ignored by git and stay. If the pull cannot be done (local changes, no network)
the start goes on with what is there and says so in `./start.sh logs`. Put
`update: no` in `config.yaml` to stop it.

## Choosing the runner

Claude Code is the default when it is installed; otherwise OpenCode is used.
Switch explicitly:

```bash
./start.sh opencode         # use OpenCode from now on, and start it
./start.sh claude           # back to Claude Code
```

`--runner opencode` (`-Runner opencode`) does the same without switching
right away. For OpenCode you can also set:

- **model**: `./start.sh --model provider/model` (list them with
  `opencode models`);
- **headless**: `./start.sh --headless` runs OpenCode without its screen - a
  local server keeps the session alive.
- **asking nobody**: OpenCode runs with `--auto` (like Claude Code's
  `--allow-dangerously-skip-permissions`), so it never stops to ask you. The
  kit still refuses what must stay refused - your token, `.env` - and, more
  than Claude Code, it refuses **any path outside the folder it runs in**: the
  agent reads and writes in there, and nowhere else on your computer. Set
  `opencode_flags` in `config.yaml` if you want different flags.

## Two accounts on one computer

A second account's agent runs beside the first: its own folder, its own token,
its own tmux session. The session's name is what keeps them apart, so give it
the name of the token the same way, and a folder of its own:

```bash
curl -fsSL https://YOUR-REDLINE-SERVER/api/public/install.sh | bash -s -- --token rlat_SECOND --dir ~/redline-agent-second --session second
```

`--session` is kept in `config.yaml`, so a later `./start.sh` in that folder
uses it too. Without it both would call their tmux session `redline-agent` and
the second would stop with "already running". A headless OpenCode takes a port
of its own from the session's name as well (`port:` in `config.yaml`, or
`REDLINE_OPENCODE_PORT`), so two of them never want 4096 at once. Everything
else is per folder already: the kit, the logs, the settings, the token, and
the service, which is named after the session
(`workbench-agent-<session>`).

## Run it as a service

To keep the agent running after a reboot:

```bash
./start.sh install          # start it again after every reboot (user service)
./start.sh uninstall        # do not start it after a reboot any more
```

The very first time you can do it in one go, when you make the token:
`./start.sh --api ... --token ... --service`. On Windows use
`start.ps1 -Install` and `start.ps1 -Uninstall`.

- **Linux**: a **systemd user service**. To start it at boot, before you log
  in, run once the line the script prints (it may ask for your password):
  `loginctl enable-linger $USER`. The script only prints it.
- **macOS**: a **LaunchAgent** (`com.workbench.workbench-agent`) that starts
  at login.
- **Windows**: `start.ps1 -Install` registers a **logon task** that runs the
  agent in WSL.

## Settings: config.yaml

Settings live in `config.yaml` next to this file - plain `key: value` lines
(`api`, `agent`, `runner`, `model`, `room_model`, `headless`, `claude_flags`,
`opencode_flags`, `session`, `port`, `update`); a `#` starts a comment. Edit it
by hand, or use the flags above.

The **token is never in `config.yaml`**: it lives only in `.env`, readable
only by you (mode 600) and never committed. Both files are in `.gitignore`.

## OpenCode

To run on OpenCode instead of Claude Code:

1. install it (https://opencode.ai/docs/) and sign in to a model provider:
   `opencode auth login`;
2. pick a model that can **read images** - the red marks on your notes are
   pictures, so the agent has to see them:
   `./start.sh --model provider/model` (`opencode models` lists them). You can
   also set a separate model for the room agents with `room_model`.

## Your token

- It lives only in `.env` in this folder: readable only by you (mode 600),
  listed in `.gitignore`, never committed. Do not paste it anywhere else.
- The one-line command contains it, so it is also in your shell history.
  On a shared computer, leave `--token` out and type it when asked.
- Everything the agent does is recorded in Workbench under the token's
  name. A token is at most an *editor* and only works in your own space.
- **Revoke it** any time under Agent tokens (*Revoke*): the agent stops at
  once. To use a new one: `./start.sh restart --token rlat_NEW`.
- Lost computer? Revoke its token; nothing else is stored there.

## Troubleshooting

- *token is unknown, revoked or expired*: make a new one and run
  `./start.sh restart --token rlat_...`.
- *Python could not make a virtual environment*: `sudo apt install python3-venv`
  (or `python3.12-venv`), or install [uv](https://docs.astral.sh/uv/).
- *CERTIFICATE_VERIFY_FAILED* on macOS: run *Install Certificates.command*
  from your Python's folder in Applications.
- Not connected in Workbench: `./start.sh status`, then
  `./start.sh attach` to see what the agent is doing.
- To choose how a runner is started, set `claude_flags` or `opencode_flags`
  in `config.yaml` (Claude Code defaults to
  `--allow-dangerously-skip-permissions`, which lets it switch to work
  without asking; the kit already allows its own commands).

## Türkçe

Bu depo, Workbench ajanınızı **kendi bilgisayarınızda** çalıştırmak için
gereken her şeyi içerir: bir başlatma betiği ve ajanın talimatları. Workbench
kaynak kodu ya da veritabanı şifresi gerekmez; ajan, sunucunuza bir ajan
anahtarıyla bağlanır ve her başlangıçta ajan kitini sunucudan indirir.
Varsayılan olarak Claude Code üzerinde, isterseniz OpenCode üzerinde çalışır.

1. **Anahtar oluşturun**: Workbench'da kullanıcı menüsü > *Ajan anahtarları*
   > *Yeni anahtar*. Anahtar (`rlat_...`) yalnızca bir kez gösterilir;
   çalıştırılacak satır da hemen orada, anahtarınız ve sunucu adresiniz
   doldurulmuş olarak çıkar.
2. **Tek satırı çalıştırın** (macOS / Linux / WSL):
   `curl -fsSL https://SUNUCUNUZ/api/public/install.sh | bash -s -- --token rlat_ANAHTARINIZ`
   Bu script sunucunuzdan gelir ve adresi içinde hazırdır; yazdığınız tek şey
   anahtardır. Depoyu `~/redline-agent-seed` içine indirir (ikinci kez
   çalıştırınca günceller) ve her şeyi `start.sh`'a devreder.
   Windows'ta `wsl bash -c "curl -fsSL https://SUNUCUNUZ/api/public/install.sh | bash -s -- --token rlat_ANAHTARINIZ"`
   satırını kullanın (ajan WSL içinde çalışır). Script'i boruya vermek yerine
   kendiniz çalıştırmak isterseniz, README'nin İngilizce bölümündeki
   "Or do it by hand" satırlarını kullanın.
3. **Açık tutun**: Ajan, kuyruğa aldığınız notlar üzerindeki işi yapan
   şeydir; geliştirdiğiniz sürece bilgisayarınızda çalışır durumda olmalı.
   Durursa notlar kuyrukta bekler. `./start.sh` yeniden başlatır (ve
   günceller), `./start.sh restart` durdurup yeniden başlatır,
   `./start.sh stop` durdurur, `./start.sh status` durumu gösterir,
   `./start.sh attach` izlemenizi sağlar, `./start.sh logs` betiğin ne
   yaptığını gösterir, `./start.sh --dry-run` yalnızca ayarları yazdırır.
   Yeniden başlayınca **son konuşmayı sürdürür**, baştan başlamaz.

**Kendini günceller**: iki parça da her başlangıçta kendini günceller, yani
kurulum satırını bir kez çalıştıran bilgisayar bir daha uğraşmaz. **Ajan
kiti** her seferinde Workbench sunucunuzdan indirilir; bu **depo** da
başlamadan önce `git pull --ff-only` ile ileri alınır - yeni `start.sh` dahil:
betik değiştiyse en baştan yeniden çalışır ve ayarlarınız, anahtarınız, tmux
oturumunuz korunur (`config.yaml`, `.env`, `logs/`, `kit/` git tarafından
yoksayılır, yerinde kalır). Güncelleme yapılamazsa (yerel değişiklik ya da ağ
yok) eldekiyle devam eder ve bunu `./start.sh logs`'ta söyler. Kapatmak için
`config.yaml` dosyasına `update: no` yazın.

**Runner seçimi**: Claude Code varsayılandır; OpenCode için
`./start.sh opencode` (geri dönmek için `./start.sh claude`), model için
`./start.sh --model provider/model`, ekransız çalıştırmak için
`./start.sh --headless`.

**Aynı bilgisayarda iki hesap**: ikinci hesabın ajanı birincinin yanında
çalışır - kendi klasörü, kendi anahtarı, kendi tmux oturumu. Onları ayıran şey
oturum adıdır; anahtara verdiğiniz adı ona da verin ve ayrı bir klasör seçin:

`curl -fsSL https://SUNUCUNUZ/api/public/install.sh | bash -s -- --token rlat_IKINCI --dir ~/redline-agent-ikinci --session ikinci`

`--session` `config.yaml`'a yazılır, o klasörde sonraki `./start.sh` de onu
kullanır. Verilmezse ikisi de tmux oturumunu `redline-agent` yapar ve ikincisi
"already running" deyip durur. Ekransız OpenCode portunu da oturum adından
alır (`config.yaml`'daki `port:` ya da `REDLINE_OPENCODE_PORT`), böylece ikisi
4096'yı paylaşmaz. Geri kalan her şey zaten klasör başına: kit, loglar,
ayarlar, anahtar ve servis (`workbench-agent-<oturum>`).

**Servis olarak**: her açılışta başlaması için `./start.sh install`,
kaldırmak için `./start.sh uninstall` (ilk seferde tek seferde
`--service` ekleyin). Linux'ta bir **systemd kullanıcı servisi** kurulur ve
açılıştan önce de çalışması için betiğin yazdırdığı
`loginctl enable-linger $USER` satırını bir kez çalıştırmanız gerekir
(betik yalnızca yazdırır, çalıştırmaz). Windows'ta `start.ps1 -Install`
oturum açılışında çalışan bir görev kurar.

**Ayarlar `config.yaml` dosyasındadır** (düz `key: value` satırları);
anahtar yalnızca bu klasördeki `.env` dosyasında durur (yalnızca siz
okuyabilirsiniz, git'e girmez); başka bir yere yapıştırmayın. Geri almak
için *Ajan anahtarları* sayfasında *Revoke*'a basın.

**OpenCode**: `opencode auth login` ile bir model sağlayıcısına giriş yapın
ve **görüntü okuyabilen** bir model seçin - notlarınızdaki kırmızı
işaretler resimdir.
