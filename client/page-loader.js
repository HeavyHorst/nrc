// Paging UI only. The owner publishes state and handles nrc:load-more;
// cursors, request cancellation and merging results remain with the data source.
class NRCPageLoader extends HTMLElement {
  state = { hasMore: false, loading: false, error: "", disabled: false, active: true, root: null, label: "LOAD MORE" };
  observer = null;
  requested = false;

  connectedCallback() {
    if (!this.button) {
      this.button = this.querySelector("button") || document.createElement("button");
      this.button.type = "button";
      this.button.classList.add("btn");
      this.button.hidden = false;
      this.status = document.createElement("span");
      this.status.setAttribute("role", "status");
      this.append(this.status, this.button);
      this.button.addEventListener("click", () => this.requestPage());
    }
    this.render();
  }

  disconnectedCallback() {
    this.observer?.disconnect();
    this.observer = null;
  }

  // Partial updates also let a persistent but hidden view suspend observation.
  setState(state) {
    Object.assign(this.state, state);
    this.requested = false;
    if (this.isConnected) this.render();
  }

  requestPage(automatic = false) {
    const { active, disabled, loading, hasMore, error } = this.state;
    if (!this.isConnected || !active || disabled || loading || this.requested ||
        (!hasMore && !error) || (automatic && error) || !this.getClientRects().length) return;
    this.requested = true;
    this.observer?.disconnect();
    this.observer = null;
    this.dispatchEvent(new CustomEvent("nrc:load-more", { bubbles: true }));
  }

  render() {
    this.observer?.disconnect();
    this.observer = null;
    const { active, disabled, loading, hasMore, error, root, label } = this.state;
    this.hidden = !hasMore && !loading && !error;
    this.setAttribute("aria-busy", String(loading));
    this.status.textContent = error;
    this.status.hidden = !error;
    this.button.textContent = loading ? "LOADING…" : error ? "RETRY" : label;
    this.button.disabled = !active || disabled || loading || (!hasMore && !error);
    if (!active || disabled || loading || !hasMore || error || this.requested ||
        typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(entries => {
      // disconnect() does not retract callbacks already queued for an old view.
      if (this.observer === observer && entries.some(entry => entry.isIntersecting)) this.requestPage(true);
    }, { root, rootMargin: "400px 0px", threshold: 0 });
    this.observer = observer;
    // Observe the whole boundary, including when a horizontally scrolled list
    // clips its centered button but still exposes part of the loaded boundary.
    observer.observe(this);
  }
}

customElements.define("nrc-page-loader", NRCPageLoader);
