# loupe-web

Review data and static site dashboard for [loupe](https://github.com/zevorn/loupe).

Live site: [zevorn.github.io/loupe-web](https://zevorn.github.io/loupe-web/)

## How It Works

1. GitHub Actions runs daily (UTC 08:00), queries Patchwork for new QEMU RISC-V patches
2. New patches are reviewed via `codex exec` with the loupe-review skill
3. Review results are saved as JSON files in `docs/reviews/`
4. GitHub Pages serves `docs/` as a static site — zero build step

## Setup

### GitHub Secrets

Configure in **Settings → Secrets and variables → Actions → Secrets**:

| Secret | Description | Codex config mapping |
|--------|-------------|---------------------|
| `OPENAI_API_KEY` | API key (bearer token) | `OPENAI_API_KEY` env var |
| `OPENAI_API_URL` | API base URL (e.g., `https://api.example.com/v1`) | `config.toml` → `base_url` |
| `OPENAI_MODEL_NAME` | Model name (e.g., `gpt-5.4`) | `config.toml` → `model` |

The workflow generates `$CODEX_HOME/config.toml` from these secrets at
runtime, since Codex CLI reads API endpoint and model from config, not
environment variables.

### GitHub Pages

Enable GitHub Pages in **Settings → Pages**:
- Source: **Deploy from a branch**
- Branch: **main**, folder: **/docs**

## Run Locally

```bash
cd docs
python3 -m http.server 8080
# Open http://localhost:8080
```

## Directory Structure

```
loupe-web/
├── .github/workflows/
│   └── daily-review.yml        # Daily cron workflow
├── docs/                        # GitHub Pages root
│   ├── index.html               # Single-page app
│   └── reviews/
│       ├── index.json           # Review index
│       └── YYYY-MM-DD/          # Daily review data
│           └── <id>.json
├── scripts/
│   ├── fetch-new-patches.sh     # Query Patchwork API
│   └── update-index.sh          # Rebuild index.json
└── README.md
```

## License

MIT License. See [LICENSE](LICENSE) for details.
