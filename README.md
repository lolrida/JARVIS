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

### Without Docker

```bash
# 1. Install Ollama: https://ollama.com/download   (then `ollama serve` if it isn't already running)
pip install -e .
jarvis serve            # http://localhost:8000 ; admin key printed and saved to ./data/admin_key.txt
```

## iPhone app

JARVIS ships its own iPhone app at **`/app`**: chat with streaming replies, switch models and versions,
👍 replies into your training data, dictate with the mic, have replies read aloud, and (with an admin key)
switch versions, edit a model's personality, or download new base models straight from your phone.
Chats are stored on the phone; replies come only from your server.

It's a web app you install from Safari. No App Store, no Apple developer account, no $99/year:

1. Make your server reachable from the phone (below).
2. On the iPhone, open **`https://<your-server>/app`** in **Safari** and sign in with a key
   (make one per device: API keys tab, or `jarvis create-key --name iphone`).
3. Tap **Share → Add to Home Screen**. It now opens full-screen from its own icon like any other app.

**Reaching your server from the phone**

- *Same Wi-Fi only:* `http://<computer's-local-IP>:8000/app` works.
- *Anywhere, securely (recommended):* install [Tailscale](https://tailscale.com) (free) on the server and the iPhone,
  then on the server run `tailscale serve --bg 8000`. It prints an `https://<machine>.<tailnet>.ts.net` address
  that only your devices can open. Use that + `/app`. HTTPS also enables the app's offline shell.

Updates ship with the server: pull the latest JARVIS, restart, and the phone picks up the new app the next time it opens.

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
