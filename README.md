# TelQuest Inventory API

A plumber-based REST API that exposes the same inventory data as the Shiny
dashboard. Designed to be given to a partner with an API key.

## Files

- `inventory.R` — Shared data-fetching logic (NetSuite + inbound CSV).
- `plumber.R`   — REST API endpoints, auth filter, cache.
- `run.R`       — Entry point.
- `Dockerfile`  — Container build.

## Endpoints

All endpoints except `/health` require the header `X-API-Key: <key>`.

| Method | Path                          | Purpose                         |
|--------|-------------------------------|---------------------------------|
| GET    | `/health`                     | Liveness check, no auth         |
| GET    | `/inventory`                  | List items with filters         |
| GET    | `/inventory/{part_number}`    | Exact lookup                    |
| POST   | `/refresh`                    | Force cache refresh             |
| GET    | `/__docs__/`                  | Interactive Swagger UI          |

### `/inventory` query params

- `part_number`   substring, case-insensitive
- `manufacturer`  exact, case-insensitive
- `condition`     exact, case-insensitive
- `in_stock_only` `true` to exclude inbound
- `on_sale_only`  `true` for promo items only
- `min_price`, `max_price`
- `limit` (default 1000), `offset` (default 0)

## Environment variables (required)

```
NETSUITE_CONSUMER_KEY=...
NETSUITE_CONSUMER_SECRET=...
NETSUITE_TOKEN_ID=...
NETSUITE_TOKEN_SECRET=...
TELQUEST_API_KEYS=partner_a_key_here,partner_b_key_here
```

Generate API keys in R:
```r
paste(openssl::rand_bytes(24), collapse = "")
```

## Run locally

```bash
Rscript run.R
# then open http://localhost:8000/__docs__/
```

## Run via Docker

```bash
docker build -t telquest-api .
docker run -d --name telquest-api -p 8000:8000 \
  -e NETSUITE_CONSUMER_KEY=... \
  -e NETSUITE_CONSUMER_SECRET=... \
  -e NETSUITE_TOKEN_ID=... \
  -e NETSUITE_TOKEN_SECRET=... \
  -e TELQUEST_API_KEYS=abc123,def456 \
  telquest-api
```

## Test

```bash
# Health
curl http://localhost:8000/health

# Cisco switches, ready to ship
curl -H "X-API-Key: abc123" \
  "http://localhost:8000/inventory?manufacturer=Cisco&in_stock_only=true&limit=10"

# Single part
curl -H "X-API-Key: abc123" \
  "http://localhost:8000/inventory/WS-C2960-24TC-L"
```

## Production deployment

Pick one:

1. **Render.com / Fly.io / Railway** — push the Dockerfile, set env vars in
   the dashboard. Easiest given the n8n/Render stack already in use.
2. **DigitalOcean droplet / AWS EC2** — install Docker, run the container,
   put nginx in front for TLS (Let's Encrypt via certbot).
3. **Posit Connect** — if licensed, deploy `plumber.R` directly. Handles
   TLS, auth, and scaling.

Whichever you pick, the partner gets:
- A base URL (e.g. `https://api.telquestintl.com`)
- An API key (one of the values in `TELQUEST_API_KEYS`)
- A link to `/__docs__/` for the Swagger spec

## Security checklist before going live

- [ ] Rotate the NetSuite TBA token currently in `app.R` — it has been
      committed to a file and should be considered compromised.
- [ ] Remove the hardcoded credentials from `app.R` and load them from the
      same env vars used here.
- [ ] Terminate TLS in front of the API (Cloudflare, nginx, or the host's
      TLS proxy). Plumber speaks HTTP only.
- [ ] Give each partner a separate key so you can revoke individually.
- [ ] Consider rate limiting at the proxy layer (nginx `limit_req`,
      Cloudflare rules) — plumber has no built-in limiter.
- [ ] Log requests to a file or stdout so you can audit usage.
