import { Hono } from "hono";
import type { WebhookPayload } from "./types";
import { formatNotification } from "./format";
import { sendBark } from "./channels/bark";

const app = new Hono<{ Bindings: CloudflareBindings }>();

app.post("/webhook/bark/:token", async (c) => {
  const token = c.req.param("token");

  let payload: WebhookPayload;
  try {
    payload = await c.req.json<WebhookPayload>();
  } catch {
    return c.json({ error: "Invalid JSON body" }, 400);
  }

  if (!payload.event) {
    return c.json({ error: "Missing 'event' field" }, 400);
  }
  console.log("Payload:", payload)
  const notification = formatNotification(payload);

  const origin = new URL(c.req.url).origin;
  const iconUrl = `${origin}/icons/${notification.iconFile}`;

  const server = c.req.query("server");

  try {
    const result = await sendBark({ token, notification, iconUrl, server });
    return c.json({ ok: true, bark: result });
  } catch (err) {
    return c.json(
      { ok: false, error: err instanceof Error ? err.message : "Bark request failed" },
      502,
    );
  }
});

export default app;
