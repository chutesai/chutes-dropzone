#!/usr/bin/env node

import fs from 'node:fs';

if (process.argv.length !== 5) {
  console.error('usage: patch-n8n-build.mjs <index.html> <css-href> <js-src>');
  process.exit(1);
}

const [, , indexPath, cssHref, jsSrc] = process.argv;
let html = fs.readFileSync(indexPath, 'utf8');

if (!html.includes(cssHref)) {
  html = html.replace(
    '</head>',
    `\t\t<link rel="stylesheet" href="${cssHref}">\n\t\t<script src="${jsSrc}" type="text/javascript" defer></script>\n\t</head>`,
  );
}

fs.writeFileSync(indexPath, html);
