# RoomyDisk website

The product site for RoomyDisk. It is plain static files with no build step:

- `index.html`: the page.
- `assets/css/site.css`, `assets/js/site.js`: styles, the 3D hero (Three.js), scroll motion and the screen tour.
- `assets/vendor/three.min.js`: Three.js r160, kept here so the site never depends on a CDN.
- `assets/img/`: app screenshots (from the redesign) and icon sizes.
- `_headers`: security and cache headers for Cloudflare Pages.
- `functions/api/contact.js`: the contact form's endpoint (a Cloudflare Pages Function).

The page reads fine without JavaScript or WebGL: the 3D disk falls back to the app icon, and Reduce Motion keeps
everything still.

## Preview locally

```sh
cd website && python3 -m http.server 8000   # then open http://localhost:8000
```

## Hosting on Cloudflare Pages

The **Deploy website** GitHub Actions workflow (`.github/workflows/deploy-website.yml`) uploads this folder to
Cloudflare Pages on every push to `main` that touches `website/`, and creates the Pages project (`roomydisk`,
served at `roomydisk.pages.dev`) on its first run. Don't also connect the repository under Workers & Pages ›
Connect to Git, or the site would deploy twice from two projects.

1. In Cloudflare open **My Profile › API Tokens › Create Token › Custom token** with the permission
   **Account › Cloudflare Pages › Edit**, and copy it.
2. In GitHub open **Settings › Secrets and variables › Actions** and add `CLOUDFLARE_API_TOKEN` (the token) and
   `CLOUDFLARE_ACCOUNT_ID` (shown on the right of the Workers & Pages overview).
3. Run **Actions › Deploy website › Run workflow** once, or push a change to `website/`.
4. Optional: **Custom domains** on the Pages project to add your own domain.

## Contact form

The form posts to `/api/contact`, a Cloudflare Pages Function (`functions/api/contact.js`). It checks the fields,
drops bot submissions (a hidden honeypot field and a minimum fill time) and emails the message to you through
[Resend](https://resend.com), with the visitor's address as Reply-To so you can answer straight from your inbox.
Your address is kept in Cloudflare's encrypted settings only, never in the page or this repository.
Resend's free plan sends 3,000 emails a month (100 a day).

1. Sign up at resend.com with the address that should receive messages, and create an API key with sending access.
2. Add `RESEND_API_KEY` (the key) and `CONTACT_TO` (the address you signed up to Resend with) as GitHub Actions
   secrets; the deploy copies them into the Pages project as encrypted secrets. Or set them yourself in
   Cloudflare Pages under **Settings › Variables and Secrets** (type **Secret**), and leave them out of GitHub.
3. Redeploy. Until both are set, the form tells visitors it isn't connected yet and points them to GitHub issues.

Without a verified domain, Resend sends from its shared `onboarding@resend.dev` address and only to your own
sign-up address, which is all a contact form needs. Once the site has its own domain, verify it in Resend and set
`CONTACT_FROM` (for example `RoomyDisk <hello@yourdomain>`).

Optional bot check: create a free Cloudflare Turnstile widget for the site, put its site key in `data-sitekey` on
`#cf-turnstile` in `index.html`, and add its secret as `TURNSTILE_SECRET`.

## Updating screenshots

Replace the files in `assets/img/` with the same names (`treemap`, `rings`, `smart-clean`, `duplicates`,
`uninstaller`, `space-hunters`, `cloud-space`, `disk-health`, `menu-bar`), as `.jpg` plus `.webp`.
