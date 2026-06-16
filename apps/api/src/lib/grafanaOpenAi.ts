import OpenAI from "openai";
import { chat_v2 } from "grafana-openai-monitoring";
import type { Env } from "../env.js";

export function createOpenAIClient(env: Env): OpenAI {
  const openai = new OpenAI({ apiKey: env.OPENAI_API_KEY });
  monitorOpenAI(openai, env);
  return openai;
}

function monitorOpenAI(openai: OpenAI, env: Env): void {
  if (
    !env.GRAFANA_OPENAI_METRICS_URL ||
    !env.GRAFANA_OPENAI_LOGS_URL ||
    !env.GRAFANA_OPENAI_METRICS_USERNAME ||
    !env.GRAFANA_OPENAI_LOGS_USERNAME ||
    !env.GRAFANA_CLOUD_ACCESS_TOKEN
  ) {
    return;
  }

  try {
    // Patch chat.completions.create so Grafana Cloud receives OpenAI usage
    // metrics and Loki logs for SDK-backed chat-completion requests.
    chat_v2.monitor(openai, {
      metrics_url: env.GRAFANA_OPENAI_METRICS_URL,
      logs_url: env.GRAFANA_OPENAI_LOGS_URL,
      metrics_username: env.GRAFANA_OPENAI_METRICS_USERNAME,
      logs_username: env.GRAFANA_OPENAI_LOGS_USERNAME,
      access_token: env.GRAFANA_CLOUD_ACCESS_TOKEN,
    });
  } catch (err) {
    console.warn("Grafana OpenAI monitoring disabled:", err);
  }
}
