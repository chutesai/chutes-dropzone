#!/usr/bin/env node

const [, , compiledRoot] = process.argv;

if (!compiledRoot) {
	console.error('Usage: patch-n8n-runtime.mjs <compiled-root>');
	process.exit(1);
}

console.log(
	`No runtime patch required for ${compiledRoot}; chutes-n8n-local now applies its n8n customizations at the source layer.`,
);
