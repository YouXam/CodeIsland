import type { NotificationData } from "../types";

const DEFAULT_BARK_SERVER = "https://api.day.app";

interface BarkOptions {
  token: string;
  notification: NotificationData;
  iconUrl: string;
  server?: string;
}

interface BarkResponse {
  code: number;
  message: string;
  timestamp: number;
}

export async function sendBark(options: BarkOptions): Promise<BarkResponse> {
  const { token, notification, iconUrl, server } = options;
  const baseUrl = server || DEFAULT_BARK_SERVER;

  const barkPayload = {
    title: notification.title,
    body: notification.body,
    level: "timeSensitive",
    icon: iconUrl,
    group: notification.group,
    isArchive: "1",
  };

  const resp = await fetch(`${baseUrl}/${token}`, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(barkPayload),
  });

  return resp.json() as Promise<BarkResponse>;
}
