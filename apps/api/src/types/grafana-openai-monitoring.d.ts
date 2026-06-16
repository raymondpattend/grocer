declare module "grafana-openai-monitoring" {
  export const chat_v2: {
    monitor(
      openai: unknown,
      options: {
        metrics_url: string;
        logs_url: string;
        metrics_username: string | number;
        logs_username: string | number;
        access_token: string;
      },
    ): void;
  };
}
