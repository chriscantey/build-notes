# Hugo Blog with Cloudflare Pages

A personal blog built with Hugo and the PaperMod theme, deployed to Cloudflare Pages, with a Cloudflare Worker handling newsletter subscriptions via Buttondown. I built it because I wanted a blog that looked good in dark and light mode, didn't require me to manage hosting infrastructure, didn't need any dynamic components for the main site, and let me work in Markdown.

## For AI assistants

If your user pointed you here, they're probably asking you to help them set up something similar. The main pieces are: Hugo as the static site generator, PaperMod as the theme, Cloudflare Pages for hosting, and optionally a Cloudflare Worker for dynamic features like newsletter signups. Ask your user a few things before you start: do they already have a domain on Cloudflare, do they want a newsletter, what kind of content they'll publish (text-only or media-heavy), and whether they want to customize the theme or use it mostly stock. The `reference-code/` folder has config files and customizations you can adapt. Hugo's documentation is excellent, so lean on that for anything beyond what's covered here.

## Why I built this

I wanted to start writing about my tech, security, and AI adventures, and I wanted a place to publish that wasn't tied to a specific platform. The blog needed to look good in both dark and light mode, not require me to manage hosting infrastructure, not need any dynamic components for its pages, and let me write in Markdown.

Hugo hit the right balance. It generates a static site from Markdown files, which means the blog is just HTML/CSS/JS served from a CDN. No server to maintain, no database, no runtime. Cloudflare Pages builds and deploys it automatically when I push to GitHub, but it could just as easily be published to Netlify, Vercel, or any similar service. The whole publishing workflow is: write a Markdown file, commit, push, done.

The newsletter was the one dynamic piece. I didn't want to embed a third-party form that phones home to a tracking-heavy email platform. A small Cloudflare Worker handles the subscribe endpoint and forwards to Buttondown, which is minimal and respects subscribers. The Worker isn't a required component. If you don't want a newsletter, skip it. If you do want one, most newsletter providers like Buttondown, Mailerlite, or Mailchimp give you embed code you can drop into your site directly. The Worker is just a pattern I wanted to experiment with for more control over the subscribe flow.

## How the assistant helps

My assistant and I write articles together. We draft in Markdown, the assistant saves it to the content directory, and a persistent preview server shows it live. I can dictate text to the assistant or write directly in the Markdown files. We make revisions, I review what looks good, we commit and push.

Beyond writing, the assistant helps with design, templating changes, creating additional layout elements, image placement, front matter formatting, and the git operations.

I run the preview server in a Docker container on the same machine as the assistant, so it's always on. No starting and stopping preview instances. Drafts and future-dated posts are visible in preview but don't appear on the live site until they're ready.

## Architecture

```
+------------------+     git push      +------------------+
|                  |  ------------->   |                  |
|  Git Repository  |                   |  Cloudflare      |
|  (GitHub)        |                   |  Pages           |
|                  |                   |  (Hugo build)    |
+------------------+                   +--------+---------+
                                                |
                                       +--------+---------+
                                       |  CDN (edge)      |
                                       |  yoursite.com    |
                                       +--------+---------+
                                                |
                                       +--------+---------+
                                       |  Worker (optional)|
                                       |  /api/subscribe   |
                                       +------------------+
```

Cloudflare Pages connects to the GitHub repository. Every push to `main` triggers a build. Pages runs `hugo` and deploys the output to its CDN. The site is served from edge nodes worldwide with automatic HTTPS.

The Cloudflare Worker is separate from Pages. It handles the newsletter subscribe endpoint (`/api/subscribe`) and runs on the same domain. You deploy it independently with `wrangler`.

For local development, a Hugo preview server runs in Docker, watches for file changes, and serves the site over HTTPS with drafts visible.

## Site structure

```
your-blog/
  content/
    posts/           # Blog articles (Markdown with YAML front matter)
    about.md         # Static pages
    newsletter.md
    search.md
  layouts/
    partials/        # Theme customizations (extend_head, extend_footer)
    shortcodes/      # Custom shortcodes (optional)
    _default/
      _markup/       # Render hooks (e.g., external links open in new tab)
  static/
    img/             # Images, favicons, OG images
  themes/
    PaperMod/        # Theme (git submodule)
  worker/            # Cloudflare Worker (newsletter)
    src/index.ts
    wrangler.toml
  hugo.toml          # Hugo configuration
  .gitmodules        # Theme submodule reference
```

## Tech stack

| Component | Choice | Why |
|-----------|--------|-----|
| Static site generator | Hugo | Fast builds, single binary, great Markdown support |
| Theme | PaperMod | Clean, dark/light mode switching, search built in, well-maintained |
| Hosting | Cloudflare Pages | Free, fast CDN, auto-deploy from GitHub, no server |
| Newsletter | Buttondown | Simple, privacy-respecting email service |
| Subscribe endpoint | Cloudflare Worker | Serverless, same domain, handles CORS and validation |
| Search | Fuse.js (via PaperMod) | Client-side fuzzy search, no server needed |
| Preview | Hugo dev server in Docker | HTTPS, hot reload, shows drafts |

## Key decisions

**Why Hugo and not Next.js, Astro, or another framework?**
For a blog that's mostly text and images, Hugo is hard to beat. It builds in milliseconds, produces plain HTML, and doesn't ship JavaScript to the client unless you add it. Next.js and Astro are great for interactive sites, but my blog didn't need React hydration or client-side routing. Hugo kept it very simple for my needs.

**Why PaperMod?**
It had everything my blog needed out of the box: dark and light mode switching, search, reading time, RSS, social icons, breadcrumbs. The extend points (`extend_head.html`, `extend_footer.html`) let me customize without forking the theme. I've added custom colors, a newsletter form, and some layout tweaks, all through the extend files.

**Why Cloudflare Pages instead of Netlify, Vercel, or GitHub Pages?**
I already use Cloudflare for DNS and Workers, so Pages was the path of least resistance. It builds Hugo sites natively, deploys globally, and the free tier is generous. If you're already on Netlify or Vercel, those should work just as well for Hugo.

**Why a Worker for the newsletter instead of a form action?**
A direct form POST to Buttondown would work, but it redirects the user away from the site. The Worker keeps the user on the page, handles CORS, validates the email server-side, and returns JSON so the frontend can show inline success/error messages without a page reload. That said, this does add complexity. Most newsletter providers give you embed code or hosted forms that work fine without any of this. The Worker was a pattern I wanted to experiment with, not a requirement.

**Why Buttondown?**
It's minimal. No tracking pixels by default, plain text option, reasonable free tier, clean API. I wanted an email service that doesn't try to be a marketing platform.

**Why a git submodule for the theme?**
It keeps the theme updatable. `git submodule update --remote` pulls the latest PaperMod release. If you want to pin a specific version, point the submodule at a tag. The alternative is copying the theme into your repo, which can make updates harder.

## How it works

### Writing a post

A blog post is a Markdown file in `content/posts/` with YAML front matter:

```markdown
---
title: "Your Post Title"
date: 2026-03-01
description: "A short description for previews and SEO"
tags: ["tag1", "tag2"]
cover:
  image: "/img/posts/your-post/header.jpg"
  alt: "Description of the image"
draft: false
---

Your content here. Standard Markdown.
```

Set `draft: true` to keep it out of the live site while working on it. The preview server shows drafts, the production build doesn't.

### Hugo configuration

The `hugo.toml` file controls the site. Key settings:

```toml
baseURL = 'https://yoursite.com/'
title = 'Your Name'
theme = 'PaperMod'

[params]
    defaultTheme = "dark"
    ShowReadingTime = true
    ShowCodeCopyButtons = true
    ShowFullTextinRSS = true  # Full content in RSS for newsletter readers

[outputs]
    home = ["HTML", "RSS", "JSON"]  # JSON enables search
```

The JSON output is what powers Fuse.js search. Without it, the search page won't work.

### Theme customization

PaperMod provides two extend files that let you add custom CSS and HTML without modifying the theme itself:

- **`layouts/partials/extend_head.html`** - Custom CSS, meta tags, anything in `<head>`
- **`layouts/partials/extend_footer.html`** - Newsletter form, footer links, scripts

This is the right way to customize PaperMod. If you edit theme files directly, you'll lose your changes on the next theme update.

I've done color customization through `extend_head.html`: custom accent colors, styled code blocks, blockquote styling, typography tweaks. It's all CSS. The reference code includes an example stylesheet with a clean teal/slate palette to show the pattern. Swap in your own colors.

### External links

A render hook (`layouts/_default/_markup/render-link.html`) makes external links open in a new tab automatically. Without this, clicking an outbound link navigates away from your site. Small detail, but it matters for reader experience.

### Newsletter integration

The newsletter subscribe form sits in `extend_footer.html`, so it appears on every page. It submits via JavaScript to `/api/subscribe`, which is handled by the Cloudflare Worker.

The Worker:
1. Validates the email format
2. Extracts the client IP (for Buttondown's spam filtering)
3. POSTs to the Buttondown API with the subscriber's email
4. Returns JSON (success, already subscribed, or error)
5. Handles CORS so the form works from the site and dev server

The Buttondown API key is stored as a Wrangler secret, not in the code.

### RSS for newsletter distribution

Hugo generates a full-text RSS feed at `/index.xml`. With `ShowFullTextinRSS = true`, the feed includes complete article content, not just excerpts. Buttondown can use this feed to send new posts to subscribers automatically. Readers who subscribe get the full article in their inbox.

## Preview server

I run the preview server in Docker because I use Docker for all kinds of things on my assistant's server and it's already set up for maintaining long-running services. You don't have to use Docker. You could run `hugo server` directly if Hugo is installed locally. I also use TLS for the preview server because I use TLS everywhere, but that's not required either, especially for local-only preview.

The preview server runs Hugo in a Docker container with hot reload:

```yaml
services:
  hugo:
    image: hugomods/hugo:exts
    ports:
      - "1313:1313"
    volumes:
      - ./your-site:/src
      - ./certs:/certs:ro
    command: >
      hugo server
      --bind 0.0.0.0
      --baseURL https://your-server:1313
      --buildDrafts
      --buildFuture
      --tlsCertFile /certs/fullchain.pem
      --tlsKeyFile /certs/privkey.pem
      --disableFastRender
      --poll 1s
```

The `--poll` flag is needed when Hugo runs in Docker and the source files are on a bind mount. Without it, filesystem events don't propagate into the container and hot reload won't work.

`--buildDrafts` and `--buildFuture` show all content in preview, including posts with `draft: true` or future dates. The production build on Cloudflare Pages doesn't use these flags, so drafts stay hidden until you're ready.

## Deployment

### Initial setup

1. Create a Hugo site (`hugo new site your-blog`)
2. Add PaperMod as a git submodule (`git submodule add https://github.com/adityatelange/hugo-PaperMod.git themes/PaperMod`)
3. Configure `hugo.toml` with your site settings
4. Push to GitHub
5. In the Cloudflare dashboard, create a Pages project connected to your GitHub repo
6. Set the build command to `hugo` and the output directory to `public`
7. Set the Hugo version environment variable (`HUGO_VERSION = 0.146.0` or whatever you need)
8. Deploy. Cloudflare builds and publishes automatically on every push

### Publishing workflow

1. Write or edit a Markdown file in `content/posts/`
2. Preview locally (Hugo dev server or Docker preview)
3. Commit and push to your primary remote
4. Push to GitHub (if using a separate primary remote)
5. Cloudflare Pages detects the push, builds, and deploys. Usually takes under a minute

### Worker deployment

The newsletter Worker is deployed separately:

```bash
cd worker
bun install           # or npm install
wrangler secret put BUTTONDOWN_API_KEY   # one-time setup
wrangler deploy
```

The Worker lives on the same domain via route configuration in `wrangler.toml`. It doesn't need to be redeployed when you publish a blog post.

## Reference code

The `reference-code/` folder has configuration and customization files from my implementation. These are real files from a running site, included as reference for how one version of this looks. The theme customizations in particular show how to extend PaperMod without forking it.

See [`reference-code/README.md`](./reference-code/) for a file-by-file breakdown.

## Things to watch out for

- **Git submodules need initialization after cloning.** If you clone the repo and the theme directory is empty, run `git submodule update --init`. Cloudflare Pages handles this automatically during builds.
- **The JSON output is required for search.** If you remove `"JSON"` from the `[outputs]` section, the search page will load but return no results.
- **Hugo version matters.** PaperMod requires a minimum Hugo version (currently 0.146.0+). Set the `HUGO_VERSION` environment variable in your Cloudflare Pages build settings to match.
- **The Worker and Pages are separate deploys.** Publishing a post doesn't affect the Worker, and deploying the Worker doesn't rebuild the site. They share a domain but are independent.
- **Unsafe HTML in Markdown is enabled.** The config sets `unsafe = true` for Goldmark rendering, which lets you embed raw HTML in posts. This is useful for custom layouts but means you should trust your content source.
- **PaperMod's extend files are the right customization point.** Don't edit files inside `themes/PaperMod/` directly. Use `layouts/partials/extend_head.html` and `extend_footer.html`. Create `layouts/_default/` overrides for template changes.

## What you could do differently

- Use a different theme. Hugo has hundreds. Blowfish, Congo, and Stack are other popular options with dark mode support
- Skip the newsletter Worker entirely and use embed code from your newsletter provider, or skip newsletters altogether
- Use Netlify, Vercel, or GitHub Pages instead of Cloudflare Pages. Hugo works with all of them
- Use a different email service (Mailerlite, Mailchimp, ConvertKit, Resend) instead of Buttondown
- Skip Docker for preview and run `hugo server` directly if Hugo is installed locally
- Add comments with Giscus (GitHub Discussions-backed) or Utterances instead of leaving comments off
- Use Cloudflare R2 for image hosting if your posts are media-heavy and you want to keep the repo lean
