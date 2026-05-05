// Upstream client. Fetches /props on startup; provides passthrough helpers.
export class UpstreamClient {
  constructor({ baseUrl, logger }) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.logger = logger;
    this.props = null; // populated by loadProps()
  }

  async loadProps() {
    try {
      const res = await fetch(`${this.baseUrl}/props`);
      if (!res.ok) {
        this.logger.warn(
          { status: res.status },
          "upstream /props returned non-OK; n_ctx unknown",
        );
        return null;
      }
      this.props = await res.json();
      // llama-server exposes default_generation_settings.n_ctx (older builds)
      // and top-level n_ctx (newer). Handle both.
      const nCtx =
        this.props.n_ctx ??
        this.props?.default_generation_settings?.n_ctx ??
        null;
      this.logger.info({ n_ctx: nCtx }, "upstream /props loaded");
      return this.props;
    } catch (err) {
      this.logger.warn(
        { err: err.message },
        "upstream /props unreachable on startup",
      );
      return null;
    }
  }

  get nCtx() {
    if (!this.props) return null;
    return (
      this.props.n_ctx ??
      this.props?.default_generation_settings?.n_ctx ??
      null
    );
  }
}
