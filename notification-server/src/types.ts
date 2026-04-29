export interface WebhookPayload {
  event: string;
  raw_event: string;
  session_id: string;
  source: string;
  cwd: string;
  tool_name: string;
  timestamp: string;
  raw: Record<string, any>;
}

export interface NotificationData {
  title: string;
  body: string;
  group: string;
  iconFile: string;
}
