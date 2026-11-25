# JARVIS — your own self-hosted AI model platform

Build, version, trade, deploy and use your own LLMs on hardware you control.
No per-token bills, no rate limits, no account, no vendor that can shut you off.

```
                      ┌──────────────────────── JARVIS (this repo) ────────────────────────┐
 any OpenAI app  ───► │ /v1/chat/completions  /v1/embeddings  /v1/models   (API keys)      │
 web UI (/)      ───► │ model registry + versions · rollback · export/import · feedback   │ ──► Ollama ──► open-weight models
 curl / scripts  ───► │ usage tracking · GGUF upload for your own fine-tuned weights       │     (llama, qwen, mistral, gemma…)
                      └────────────────────────────────────────────────────────────────────┘
```

## The honest part

"Free forever" means *free software on hardware you already own*. JARVIS and Ollama are open source and
cost nothing, and the models are free open-weight downloads. What still costs something:

- **Electricity** for whatever machine runs it (a desktop left on 24/7 is roughly $5–30/month depending on hardware and rates).
- **Hardware limits what you can run.** A laptop with 8 GB RAM runs 1–4B models fine; 16 GB runs 7–8B;
  a GPU with 12–24 GB VRAM makes 7–14B models fast and 30B+ possible. Frontier-size models aren't realistic at home.
- **Training** (true fine-tuning) needs a decent GPU. You can borrow one for free for short sessions
  (Google Colab / Kaggle free tiers), then bring the weights home — see [Fine-tuning](#fine-tuning-your-own-weights).

## Quick start (Docker — recommended for 24/7)

```bash
git clone <this repo> && cd JARVIS
docker compose up -d
docker compose logs jarvis | grep "admin key"     # your admin key (also in the jarvis-data volume: admin_key.txt)
```

Open **http://localhost:8000**, paste the key, then:

1. **Base models** → download one, e.g. `llama3.2:3b` (2 GB, runs on almost anything) or `qwen2.5:7b`.
2. **My models** → create `my-assistant` from that base with your own system prompt and settings.
3. **Chat** → talk to it. 👍 good answers to build a dataset.

`restart: unless-stopped` brings everything back after crashes and reboots. Using an NVIDIA GPU? Uncomment the
`deploy:` block in `docker-compose.yml`.

Running the server on **Windows**: install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
and use the same command in PowerShell from the `JARVIS` folder. NVIDIA GPUs work through WSL 2 with the
`deploy:` block uncommented.

### Without Docker

```bash
# 1. Install Ollama: https://ollama.com/download   (then `ollama serve` if it isn't already running)
pip install -e .
jarvis serve            # http://localhost:8000 ; admin key printed and saved to ./data/admin_key.txt
```

## iPhone app (native)

`ios/` holds a native SwiftUI app for iPhone and iPad (iOS 17+):

- Chat with your models with live streaming replies, markdown and code blocks, and a stop button
- Pick any model or pinned version from the title bar
- Chat history saved on the phone; swipe to delete
- Copy, read aloud, or 👍/👎 each reply (👍 conversations become training data)
- With an admin key: switch or roll back versions, edit a model's personality and save it as a new version
  (optionally learning from your 👍 replies), and download base models to the server with a progress bar
- API key kept in the iOS Keychain; light and dark mode; haptics; Dynamic Type

### Put it on your iPhone from Windows (no Mac needed)

GitHub builds the app for you on one of its Macs; you install it from your Windows PC with a free tool.

1. **Get the app file.** On github.com, open this repository → **Actions** → **iOS app**. Open the latest
   green run (or click **Run workflow** to start one, about 4 minutes), then download **JARVIS-ipa**
   under *Artifacts*. Unzip it to get `JARVIS.ipa`.
2. **Install a sideloading tool on the PC**, either:
   - [Sideloadly](https://sideloadly.io): simplest. Plug in the iPhone, drag `JARVIS.ipa` into Sideloadly,
     enter your Apple ID, press **Start**.
   - [AltStore](https://altstore.io) (AltServer for Windows): a bit more setup, but it can **re-sign the app
     automatically over Wi-Fi** while your PC is on, so you don't have to redo it every week.

   Both may ask you to install iTunes and iCloud from Apple's website (not the Microsoft Store versions).
   A free Apple ID works; consider making a separate one just for this.
3. **On the iPhone**, the first time: Settings → Privacy & Security → turn on **Developer Mode** (the phone
   restarts), then Settings → General → **VPN & Device Management** → trust your Apple ID.
4. Open JARVIS, enter your server address and an API key (`jarvis create-key --name iphone`).

### Put it on your iPhone from a Mac

1. Open `ios/JARVIS.xcodeproj` in Xcode 16 or newer.
2. Click the **JARVIS** target → **Signing & Capabilities** → **Team** → add your Apple ID and pick it.
   Change **Bundle Identifier** from `com.yourname.jarvis` to something unique, e.g. `com.<yourname>.jarvis`.
3. Plug in your iPhone, select it at the top of Xcode, and press **Run** (▶). Developer Mode and trusting the
   developer work the same as step 3 above.

### Apple's rules (honest version)

- With a **free Apple ID**, apps you install yourself stop opening after **7 days**. Re-install (Sideloadly or
  Xcode) or let AltStore refresh it; your chats and settings are kept. Free IDs can have at most 3 such apps at once.
- A paid **Apple Developer Program** membership ($99/year) makes installs last a year and allows TestFlight,
  which installs over the air with no PC at all. GitHub Actions can build and upload to TestFlight for you;
  it needs that membership plus signing keys stored as repository secrets.
- Publishing on the App Store needs the same membership and Apple's review.

### Reaching your server from the phone

- *Same Wi-Fi only:* use your computer's local IP and port, like `192.168.1.20:8000`. iOS asks once for local network permission.
- *Anywhere, securely (recommended):* install [Tailscale](https://tailscale.com) (free) on the server and the iPhone,
  then on the server run `tailscale serve --bg 8000`. It prints an `https://<machine>.<tailnet>.ts.net` address
  that only your devices can open.

### No sideloading at all?

The server also serves a web version of the app at `/app`. Open it in Safari on the iPhone and use
**Share → Add to Home Screen**. No PC tools, no Apple account, no 7-day limit.

## Using your models from code

It speaks the OpenAI API, so most AI tools and SDKs work by changing the base URL:

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8000/v1", api_key="jv-...")

client.chat.completions.create(model="my-assistant", messages=[...])      # active version
client.chat.completions.create(model="my-assistant@v2", messages=[...])   # pin a version
client.chat.completions.create(model="qwen2.5:7b", messages=[...])        # any base model
```

```bash
curl http://localhost:8000/v1/chat/completions -H "Authorization: Bearer jv-..." \
  -H "Content-Type: application/json" \
  -d '{"model":"my-assistant","messages":[{"role":"user","content":"Hello"}],"stream":true}'
```

Make a separate non-admin key per app (**API keys** tab or `jarvis create-key --name phone-app`) so you can revoke one without breaking the others.

## Develop → iterate → deploy

| Step | UI | API |
|---|---|---|
| Create a model | My models → Create | `POST /api/models {name, base, system, parameters, examples}` |
| New version (inherits whatever you don't change) | New version | `POST /api/models/{name}/versions {system?, base?, parameters?, examples?, notes, activate}` |
| Bake 👍 conversations in as examples | "Add my 👍 conversations" | `... /versions {"examples_from_feedback": 20}` |
| Deploy / roll back | Activate | `POST /api/models/{name}/activate {version}` |
| A/B test | — | call `name@v3` vs `name@v4` side by side |
| Export the training dataset (chat JSONL) | Dataset | `GET /api/models/{name}/dataset` |
| Watch usage | Usage | `GET /api/usage?days=30` |

Every app that calls `my-assistant` gets the new version the moment you activate it, with no client changes.

## Trading models

**Export** gives you a small `.jarvis.json` bundle: every version's base, system prompt, parameters and examples.
Send it to anyone running JARVIS; they **Import** it (base models download automatically). Use `as_name` to rename it on import.

Versions built on your own uploaded weights reference the weights by SHA-256 digest. Share the `.gguf` file
alongside the bundle, and the receiver uploads it first (below) so the digest is present.

## Fine-tuning your own weights

Prompting, parameters and examples get you a long way. For a model that has truly *learned* your data:

1. Collect data: 👍 replies in Chat, then download **Dataset** (`{"messages": [...]}` per line, the format most trainers accept).
2. Train a LoRA on a GPU. [Unsloth](https://github.com/unslothai/unsloth) has free Colab notebooks for Llama/Qwen/Gemma/Mistral
   that take exactly this JSONL and can export straight to GGUF (`model.save_pretrained_gguf(...)`).
   Alternatively merge the adapter and convert with llama.cpp's `convert_hf_to_gguf.py`.
3. Upload the `.gguf` as a new version:

   ```bash
   curl -X PUT "http://localhost:8000/api/models/my-assistant/gguf?notes=lora-v1" \
     -H "Authorization: Bearer jv-ADMIN" --data-binary @my-model-Q4_K_M.gguf
   ```

   It's now `my-assistant@vN` (and active). Iterate prompts on top of it like any other version.

## Reaching it from anywhere

Keep port 8000 off the public internet. Easiest safe option: install [Tailscale](https://tailscale.com) (free for personal use)
on the server and your phone/laptop, then `tailscale serve --bg 8000` gives you a private HTTPS address for it.
If you must expose it publicly, put it behind HTTPS (e.g. Caddy or Cloudflare Tunnel) and keep keys secret.

## Configuration

| Env var | Default | |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | where the inference engine is |
| `JARVIS_DATA_DIR` | `./data` | SQLite DB, bootstrap key, temp uploads |
| `JARVIS_ADMIN_KEY` | *(generated)* | fix the admin key instead of generating one |
| `JARVIS_REQUEST_TIMEOUT` | `600` | seconds per engine call |

CLI: `jarvis serve`, `jarvis create-key --name X [--admin]`, `jarvis list-keys`, `jarvis revoke-key ID`.
Full interactive API docs: **http://localhost:8000/docs**.

**Backups:** everything JARVIS knows is in `data/jarvis.db` (models, versions, keys, datasets). Exports double as backups.

## Development

```bash
pip install -e '.[dev]'
pytest
```

Tests run against a fake engine and a mock of Ollama's HTTP API, so no model download is needed.
