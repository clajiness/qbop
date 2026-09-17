# Vendored browser assets

No frontend build step or Node runtime is needed. These unmodified assets are
served locally. Versions follow the [HTMX SSE installation guidance](https://htmx.org/extensions/sse/).

| Local file | Upstream source | SHA-256 |
| --- | --- | --- |
| `htmx-2.0.10.min.js` | https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js | `71ea67185bfa8c98c39d31717c6fce5d852370fcdfd129db4543774d3145c0de` |
| `htmx-ext-sse-2.2.4.js` | https://cdn.jsdelivr.net/npm/htmx-ext-sse@2.2.4/dist/sse.js | `3b5992a541619babefc4c169505af474df5c3039da51e59b96ccf9241ecd61d2` |

Licenses are kept in the top-level `licenses/` directory:
[HTMX](../../../licenses/htmx-LICENSE) and
[SSE extension](../../../licenses/htmx-ext-sse-LICENSE).
They are also included in the container at `/opt/qbop/licenses/`.

To update, download explicitly pinned upstream files,
update these checksums and the layout's filenames, then verify named SSE triggers
and reconnection in a browser.
