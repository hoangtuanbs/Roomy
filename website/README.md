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

Cloudflare builds and serves the site from this repository on its own side, so no GitHub Actions run.

1. In the Cloudflare dashboard open **Workers & Pages › Create › Pages › Connect to Git** and pick `hoangtuanbs/roomy`.
2. Production branch: `main`. Framework preset: **None**. Build command: leave empty.
   **Root directory: `website`**. Build output directory: `.` (so `functions/` is picked up for the contact form).
3. Optional: under **Settings › Builds › Build watch paths** include only `website/*`, so app-only commits don't redeploy the site.
4. Optional: **Custom domains** to add your own domain.

Pull requests get their own preview URL from Cloudflare automatically.

## Contact form

The form posts to `/api/contact`, a Cloudflare Pages Function (`functions/api/contact.js`). It checks the fields,
drops bot submissions (a hidden honeypot field) and forwards the message to [Formspree](https://formspree.io), which
emails it to you. Your address is kept in Formspree only, never in the page or this repository.

1. Sign up at formspree.io with the address that should receive messages, and create a form.
2. Copy the form's ID (the part after `/f/` in its endpoint, such as `xyzabcde`).
3. In Cloudflare Pages open **Settings › Variables and Secrets**, add `FORMSPREE_FORM_ID` with that ID for
   Production (and Preview if you like), then redeploy.

Until the variable is set, the form tells visitors it isn't connected yet and points them to GitHub issues.

## Updating screenshots

Replace the files in `assets/img/` with the same names (`treemap`, `rings`, `smart-clean`, `duplicates`,
`uninstaller`, `space-hunters`, `cloud-space`, `disk-health`, `menu-bar`), as `.jpg` plus `.webp`.
