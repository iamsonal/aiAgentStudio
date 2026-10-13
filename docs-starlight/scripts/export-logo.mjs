// Exports every logo PNG from the still source SVGs in brand/, and copies the logo into the
// docs site and the Pluto Lightning app. Edit the SVGs, then run `npm run logo`.

import sharp from 'sharp';
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const site = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(site, '..');
const brand = join(repo, 'brand');
const png = join(brand, 'png');
mkdirSync(png, { recursive: true });

const render = (svg, size, out) =>
  sharp(readFileSync(join(brand, svg)), { density: Math.ceil((72 * size) / 64) * 2 })
    .resize(size, size)
    .png({ compressionLevel: 9 })
    .toFile(out);

for (const size of [16, 32, 64, 128, 256, 512]) {
  await render('pluto-logo.svg', size, join(png, `pluto-logo-${size}.png`));
  await render('pluto-logo-tile.svg', size, join(png, `pluto-logo-tile-${size}.png`));
}

// Docs site: the blinking SVG in the header, the still SVG as favicon, and a PNG favicon
// for old browsers.
copyFileSync(join(brand, 'pluto-logo-animated.svg'), join(site, 'src/assets/logo.svg'));
copyFileSync(join(brand, 'pluto-logo.svg'), join(site, 'public/favicon.svg'));
await render('pluto-logo.svg', 32, join(site, 'public/favicon.png'));

// Pluto Lightning app: Salesforce shows the app logo as a square icon, so it gets the tile.
await render('pluto-logo-tile.svg', 256, join(repo, 'pluto-console/main/default/contentassets/logo.asset'));

console.log('Logo exported to brand/png, the docs site, and the Pluto app.');
