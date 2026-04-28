# CodeIsland Relay Server

Self-hosted relay server for remote CodeIsland agents.

```bash
bun run server.ts
```

Environment:

- `PORT` or `CODEISLAND_RELAY_PORT`: listen port, default `8787`
- `CODEISLAND_RELAY_DB`: SQLite database path, default `relay-data/codeisland-relay.sqlite`
- `CODEISLAND_RELAY_REQUEST_TIMEOUT_MS`: blocking permission/question timeout, default `300000`

Endpoints:

- `POST /api/register` returns `{ "apiKey": "..." }`
- `POST /api/event` accepts one-shot remote hook events
- `GET /ws` accepts CodeIsland viewer WebSocket clients
- `GET /health` returns basic health state
- `GET /resources/install.sh` remote machine installer
- `GET /resources/codeisland-relay-hook.py` remote hook script
