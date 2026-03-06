# Reference Code

Configuration and customization files from a running Hugo blog with PaperMod. These are real files, included so you can see how one version of this actually looks. They're not meant to be copied verbatim. Read through them to understand the patterns, then build your own.

## Files

| File | What it is |
|------|------------|
| `hugo.toml` | Hugo site configuration. Theme settings, menu, social icons, output formats. |
| `extend_head.html` | Example CSS injected into `<head>`. Shows how to override PaperMod's CSS variables for both dark and light mode, style code blocks, blockquotes, and typography. Uses a neutral teal/slate palette as a starting point. |
| `extend_footer.html` | Newsletter subscribe form, footer links, and inline JavaScript for form submission. Appears on every page. |
| `render-link.html` | Markdown render hook that opens external links in a new tab. |
| `worker.ts` | Cloudflare Worker that handles newsletter subscriptions via the Buttondown API. |
| `wrangler.toml` | Cloudflare Worker configuration with route mapping. |
| `docker-compose.yml` | Preview server setup using Hugo in Docker with HTTPS and hot reload. |

## Notes

- The `extend_head.html` file is an example starting point, not my actual site's design. It shows the pattern for overriding PaperMod's CSS variables and styling components. Replace the teal/slate colors with your own palette.
- The Worker handles CORS for multiple domains. Adjust the allowed origins list for your setup.
- The preview server's `docker-compose.yml` uses TLS certificates and a custom base URL. Adjust these for your environment, or drop TLS entirely for local-only preview.
- Social icon URLs, site title, and domain references have been left generic where possible. Replace them with your own.
