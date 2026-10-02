// =============================================================================
// PORTAL - NRC Design System
// =============================================================================
// Reusable portal utility for rendering elements outside their DOM hierarchy.
// Useful for dropdowns, tooltips, modals that need to escape overflow:hidden.
//
// Usage:
//   const portal = Portal.create(content, anchor, options);
//   portal.show();
//   portal.hide();
//   portal.destroy();

const Portal = {
    // Container for all portaled elements
    _container: null,

    // Active portals for cleanup
    _portals: new Set(),

    // Get or create the portal container
    getContainer() {
        if (!this._container) {
            this._container = document.createElement('div');
            this._container.id = 'portal-container';
            this._container.style.cssText = 'position:absolute;top:0;left:0;width:0;height:0;overflow:visible;pointer-events:none;z-index:10000;';
            document.body.appendChild(this._container);
        }
        return this._container;
    },

    /**
     * Create a portal instance
     * @param {HTMLElement} content - Element to portal (will be moved to body)
     * @param {HTMLElement} anchor - Element to position relative to
     * @param {Object} options - Positioning options
     * @param {string} options.position - 'bottom' | 'top' (default: 'bottom')
     * @param {string} options.align - 'left' | 'right' | 'center' (default: 'left')
     * @param {Element} options.boundary - Optional horizontal clipping boundary
     * @param {number} options.offsetY - Vertical offset in pixels (default: 0)
     * @param {number} options.offsetX - Horizontal offset in pixels (default: 0)
     * @param {boolean} options.matchWidth - Match anchor width (default: true)
     * @param {boolean} options.flipIfNeeded - Flip position if not enough space (default: true)
     * @returns {Object} Portal instance with show/hide/destroy/reposition methods
     */
    create(content, anchor, options = {}) {
        const config = {
            position: options.position || 'bottom',
            align: options.align || 'left',
            boundary: options.boundary || null,
            offsetY: options.offsetY ?? 0,
            offsetX: options.offsetX ?? 0,
            matchWidth: options.matchWidth ?? true,
            flipIfNeeded: options.flipIfNeeded ?? true
        };

        const wrapper = document.createElement('div');
        wrapper.className = 'portal-wrapper';
        wrapper.style.cssText = 'position:absolute;pointer-events:auto;';

        let settleRafId = 0;
        let settleResizeObserver = null;
        let originPlaceholder = null;

        const stopSettleLoop = () => {
            if (settleRafId) {
                cancelAnimationFrame(settleRafId);
                settleRafId = 0;
            }
        };

        const startSettleLoop = (durationMs = 400) => {
            const deadline = performance.now() + durationMs;
            stopSettleLoop();

            const tick = (now) => {
                if (!instance.isVisible) {
                    settleRafId = 0;
                    return;
                }

                instance.reposition();

                if (now < deadline) {
                    settleRafId = requestAnimationFrame(tick);
                } else {
                    settleRafId = 0;
                }
            };

            settleRafId = requestAnimationFrame(tick);
        };

        const setupResizeObserver = () => {
            if (typeof ResizeObserver === 'undefined' || settleResizeObserver) return;

            settleResizeObserver = new ResizeObserver(() => {
                if (!instance.isVisible) return;
                instance.reposition();
                // Keep the portal locked while layout settles after content/anchor size changes.
                startSettleLoop(250);
            });

            settleResizeObserver.observe(content);
            settleResizeObserver.observe(anchor);
        };

        const teardownResizeObserver = () => {
            if (!settleResizeObserver) return;
            settleResizeObserver.disconnect();
            settleResizeObserver = null;
        };

        const instance = {
            content,
            wrapper,
            anchor,
            config,
            isVisible: false,

            show: () => {
                if (instance.isVisible) return;
                if (content.parentNode !== wrapper) {
                    originPlaceholder?.remove();
                    originPlaceholder = null;
                    if (content.parentNode) {
                        originPlaceholder = document.createComment('portal-origin');
                        content.parentNode.insertBefore(originPlaceholder, content);
                    }
                    wrapper.appendChild(content);
                }
                Portal.getContainer().appendChild(wrapper);
                instance.isVisible = true;
                setupResizeObserver();
                instance.reposition();
                // Defer reposition to next frame so content is rendered
                requestAnimationFrame(() => instance.reposition());
                // Reposition for a short settling window to absorb asynchronous layout shifts.
                startSettleLoop(400);
                Portal._portals.add(instance);
            },

            hide: () => {
                if (!instance.isVisible) return;
                stopSettleLoop();
                teardownResizeObserver();
                wrapper.remove();
                instance.isVisible = false;
                Portal._portals.delete(instance);
                if (originPlaceholder?.isConnected) {
                    originPlaceholder.replaceWith(content);
                    originPlaceholder = null;
                }
            },

            destroy: () => {
                instance.hide();
                wrapper.remove();
                originPlaceholder?.remove();
                originPlaceholder = null;
            },

            reposition: () => {
                if (!instance.isVisible) return;

                const anchorRect = anchor.getBoundingClientRect();

                // Width must be applied before measuring so placement uses final wrapped height.
                if (config.matchWidth) {
                    if (config.align === 'auto') {
                        wrapper.style.width = '';
                        wrapper.style.minWidth = anchorRect.width + 'px';
                    } else {
                        wrapper.style.width = anchorRect.width + 'px';
                        wrapper.style.minWidth = '';
                    }
                } else {
                    wrapper.style.width = '';
                    wrapper.style.minWidth = '';
                }

                const contentRect = wrapper.getBoundingClientRect();
                const viewportHeight = window.innerHeight;
                const viewportWidth = window.innerWidth;

                let top, left;
                let actualPosition = config.position;

                // Calculate vertical position
                if (config.position === 'bottom') {
                    top = anchorRect.bottom + config.offsetY;
                    // Flip to top if not enough space below
                    if (config.flipIfNeeded && top + contentRect.height > viewportHeight) {
                        const topPosition = anchorRect.top - contentRect.height - config.offsetY;
                        if (topPosition > 0) {
                            top = topPosition;
                            actualPosition = 'top';
                        }
                    }
                } else {
                    top = anchorRect.top - contentRect.height - config.offsetY;
                    // Flip to bottom if not enough space above
                    if (config.flipIfNeeded && top < 0) {
                        const bottomPosition = anchorRect.bottom + config.offsetY;
                        if (bottomPosition + contentRect.height < viewportHeight) {
                            top = bottomPosition;
                            actualPosition = 'bottom';
                        }
                    }
                }

                const boundaryRect = config.boundary
                    ? config.boundary.getBoundingClientRect()
                    : { left: 4, right: viewportWidth - 4 };

                // Calculate horizontal position
                switch (config.align) {
                    case 'auto':
                        left = anchorRect.left + config.offsetX;
                        if (left + contentRect.width > boundaryRect.right) {
                            left = anchorRect.right - contentRect.width + config.offsetX;
                        }
                        break;
                    case 'right':
                        left = anchorRect.right - contentRect.width + config.offsetX;
                        break;
                    case 'center':
                        left = anchorRect.left + (anchorRect.width - contentRect.width) / 2 + config.offsetX;
                        break;
                    case 'left':
                    default:
                        left = anchorRect.left + config.offsetX;
                        break;
                }

                // Clamp to viewport
                left = Math.max(boundaryRect.left, Math.min(left, boundaryRect.right - contentRect.width));
                left = Math.max(4, Math.min(left, viewportWidth - contentRect.width - 4));
                top = Math.max(4, Math.min(top, viewportHeight - contentRect.height - 4));

                wrapper.style.left = (left + window.scrollX) + 'px';
                wrapper.style.top = (top + window.scrollY) + 'px';

                // Add position class for styling (e.g., arrow direction)
                wrapper.dataset.position = actualPosition;
            }
        };

        return instance;
    },

    // Reposition all visible portals (call on scroll/resize)
    repositionAll() {
        this._portals.forEach(portal => portal.reposition());
    },

    // Hide all portals
    hideAll() {
        this._portals.forEach(portal => portal.hide());
    }
};

// Reposition on scroll/resize
window.addEventListener('scroll', () => Portal.repositionAll(), { passive: true, capture: true });
window.addEventListener('resize', () => Portal.repositionAll(), { passive: true });
